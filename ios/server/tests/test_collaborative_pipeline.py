import copy
import json

import pytest
from pydantic import ValidationError

from test_api import body
from translation_service.ledger import content_hash
from translation_service.models import Stage, TranslationRequest, source_units
from translation_service.prompts import translation_messages


def modern(stage="proofread"):
    payload = body()
    payload["options"].update(quality="publication", pipelineVersion=2)
    payload.update(source="The train left at 8:15.\n\nHenry was late.", draft="火车开走了。亨利迟到了。", stage=stage, chunkIndex=3)
    if stage in ("proofread", "linguist"):
        payload["reviewMode"] = True
    return payload


def feedback(role, paragraph="p1", quote="8:15"):
    return {"role": role, "report": {"findings": [{"paragraphID": paragraph, "kind": "omission", "severity": "critical", "sourceQuote": quote, "explanation": "Departure time omitted", "suggestedTranslation": "八点十五分"}]}}


@pytest.mark.parametrize("role", ["proofread", "linguist"])
def test_report_mode_reviews_original_immutable_draft_and_preserves_style(role):
    payload = modern(role)
    payload["chapterContext"] = "FULL CURRENT CHAPTER: source and immutable initial drafts"
    request = TranslationRequest.model_validate(payload)
    messages = translation_messages(request)
    system, data = messages[0]["content"], json.loads(messages[1]["content"])
    assert "Do not rewrite the draft" in system
    assert 'JSON object {"findings":[]}' in system
    assert "exact nonempty quote" in system and "at most six" in system
    assert request.options.style.instruction in system
    assert data["draft"] == payload["draft"]
    assert data["sourceUnits"] == [{"id": "p1", "text": "The train left at 8:15."}, {"id": "p2", "text": "Henry was late."}]
    assert data["chapterContext"] == payload["chapterContext"]


def test_chief_integrates_both_reviewers_and_rejects_preference_only_rewrites():
    payload = modern("editor")
    payload["reviews"] = [feedback("proofread"), feedback("linguist")]
    messages = translation_messages(TranslationRequest.model_validate(payload))
    system, data = messages[0]["content"], json.loads(messages[1]["content"])
    assert "CHIEF EDITOR INTEGRATION" in system
    assert "reject preference-only rewrites" in system
    assert "resolve conflicts" in system and "necessity, concision and placement" in system
    assert data["reviewerFeedback"] == payload["reviews"]
    assert data["draft"] == payload["draft"]


@pytest.mark.parametrize("mutation", ["wrong_quote", "wrong_paragraph", "duplicate_role", "missing_reports", "unbounded_context", "verify"])
def test_invalid_collaboration_contract_rejected(mutation):
    payload = modern("editor")
    payload["reviews"] = [feedback("proofread"), feedback("linguist")]
    if mutation == "wrong_quote":
        payload["reviews"][0]["report"]["findings"][0]["sourceQuote"] = "invented source"
    elif mutation == "wrong_paragraph":
        payload["reviews"][0]["report"]["findings"][0]["paragraphID"] = "p2"
    elif mutation == "duplicate_role":
        payload["reviews"][1]["role"] = "proofread"
    elif mutation == "missing_reports":
        payload.pop("reviews")
    elif mutation == "unbounded_context":
        payload["chapterContext"] = "x" * 32001
    else:
        payload["stage"] = "verify"
    with pytest.raises(ValidationError):
        TranslationRequest.model_validate(payload)


@pytest.mark.parametrize("quality", ["publication", "definitive"])
def test_new_highest_grade_has_no_final_verifier_but_old_tasks_keep_it(quality):
    payload = body()
    payload["options"].update(quality=quality, pipelineVersion=2)
    new = TranslationRequest.model_validate(payload)
    assert new.options.allowed_stages() == [Stage.translate, Stage.proofread, Stage.linguist, Stage.editor]
    payload["options"].pop("pipelineVersion")
    old = TranslationRequest.model_validate(payload)
    assert (Stage.verify in old.options.allowed_stages()) == (quality == "definitive")


def test_report_mode_is_not_allowed_for_direct_translation_or_legacy_pipeline():
    for stage, version in [("translate", 2), ("editor", 2), ("proofread", None)]:
        payload = modern(stage)
        payload.update(reviewMode=True)
        payload["options"]["pipelineVersion"] = version
        with pytest.raises(ValidationError):
            TranslationRequest.model_validate(payload)


def test_legacy_optional_fields_do_not_change_paid_request_hash():
    old = body()
    expanded = copy.deepcopy(old)
    expanded.update(reviewMode=None, reviews=None, chapterContext=None, chunkIndex=None)
    expanded["options"]["pipelineVersion"] = None
    assert content_hash("translate", old) == content_hash("translate", expanded)
    expanded["options"]["pipelineVersion"] = 2
    assert content_hash("translate", old) != content_hash("translate", expanded)
    report = modern("editor")
    report["reviews"] = [feedback("proofread"), feedback("linguist")]
    changed = copy.deepcopy(report)
    changed["reviews"][0]["report"]["findings"][0]["suggestedTranslation"] = "另一修正"
    assert content_hash("translate", report) != content_hash("translate", changed)


def test_source_units_preserve_paragraph_identity_across_crlf_and_blank_lines():
    assert source_units(" A\r\n\r\n \t\r\n B \r\n") == [{"id": "p1", "text": "A"}, {"id": "p2", "text": "B"}]


def test_paid_report_and_chief_replay_once_and_changed_feedback_is_rejected(settings):
    from test_api import setup_client
    from translation_service.billing import TokenUsage, UsageText

    class CollaborativeModel:
        calls = 0

        async def complete(self, messages, *, max_tokens=None):
            self.calls += 1
            text = '{"findings":[]}' if "REVIEW REPORT MODE" in messages[0]["content"] else "完整译稿"
            return UsageText(text, TokenUsage(20, 10))

    model = CollaborativeModel()
    app, client, owner, headers = setup_client(settings, model)
    with client:
        report = modern()
        report["requestID"] = "book-p2-3-proofread"
        for _ in range(2):
            response = client.post("/v1/translate", json=report, headers=headers)
            assert response.status_code == 200 and response.json()["text"] == '{"findings":[]}'
        assert model.calls == 1
        assert app.state.ledger.account(owner)["points"] == 99
        chief = modern("editor")
        chief.update(requestID="book-p2-3-editor", reviews=[feedback("proofread"), feedback("linguist")])
        for _ in range(2):
            response = client.post("/v1/translate", json=chief, headers=headers)
            assert response.status_code == 200 and response.json()["text"] == "完整译稿"
        assert model.calls == 2
        assert app.state.ledger.account(owner)["points"] == 98
        chief["reviews"][0]["report"]["findings"][0]["suggestedTranslation"] = "changed proposal"
        assert client.post("/v1/translate", json=chief, headers=headers).status_code == 409
        assert model.calls == 2 and app.state.ledger.account(owner)["points"] == 98
