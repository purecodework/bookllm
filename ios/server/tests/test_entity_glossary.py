import copy
import json

import pytest
from pydantic import ValidationError

from test_api import body
from translation_service.billing import TokenBudget
from translation_service.ledger import content_hash
from translation_service.models import GlossaryRequest, Term, TranslationRequest
from translation_service.prompts import glossary_messages, translation_messages


def test_compact_query_carries_only_new_candidates_and_limited_known_entities():
    request = GlossaryRequest(requestID="book-g2-terms-0", source="Elizabeth, whom everyone called Liz, waved.", target="简体中文", mode="entities-v1", candidates=["Liz"], known=[Term(source="Elizabeth", target="伊丽莎白", category="person", entityID="e2-elizabeth")])
    messages = glossary_messages(request)
    data = json.loads(messages[1]["content"])
    assert data["candidates"] == ["Liz"]
    assert data["known"][0]["entityID"] == "e2-elizabeth"
    assert "evidence must explicitly link both spellings" in messages[0]["content"]
    assert "nickname" in messages[0]["content"]


@pytest.mark.parametrize("change", [dict(candidates=["invented"]), dict(candidates=["Liz", "liz"]), dict(mode=None), dict(known=[dict(source="Mary", target="玛丽")]*17)])
def test_compact_query_rejects_unanchored_duplicates_unversioned_and_oversized_context(change):
    payload = dict(requestID="q", source="Liz waved.", target="中文", mode="entities-v1", candidates=["Liz"])
    payload.update(change)
    with pytest.raises(ValidationError):
        GlossaryRequest.model_validate(payload)


def test_ambiguous_name_never_matches_month_context_or_a_substring():
    term = Term(source="May", target="梅", category="person", ambiguous=True, evidence="May said hello.")
    assert term.relevant_to("May said hello.")
    assert not term.relevant_to("The flowers opened in May.")
    assert not Term(source="Mary", target="玛丽", category="person").relevant_to("Maryland")
    assert Term(source="Mary", target="玛丽").relevant_to("Maryland")


def test_ambiguous_entries_require_scope_and_aliases_have_limits():
    with pytest.raises(ValidationError):
        Term(source="May", target="梅", category="person", ambiguous=True)
    with pytest.raises(ValidationError):
        Term(source="Liz", target="丽兹", aliases=["x"]*9)
    with pytest.raises(ValidationError):
        Term(source="Liz", target="丽兹", aliases=["x"*201])


def test_capture_removes_redundant_source_units_and_preserves_style_contract():
    payload = body(); payload["glossaryCapture"] = True
    payload["options"]["pipelineVersion"] = 2
    request = TranslationRequest.model_validate(payload)
    messages = translation_messages(request)
    data = json.loads(messages[1]["content"])
    assert "sourceUnits" not in data and data["source"] == payload["source"]
    assert request.options.style.instruction in messages[0]["content"]
    assert "PRIVATE trailer" in messages[0]["content"]
    assert "At most 12" in messages[0]["content"]
    assert "target must appear verbatim" in messages[0]["content"]


@pytest.mark.parametrize("change", [dict(stage="proofread", draft="初译"), dict(source="Use <bookllm-glossary-v1> literally."), dict(source="Use </bookllm-glossary-v1> literally.")])
def test_capture_only_initial_translation_and_never_literal_source_markers(change):
    payload = body(); payload["options"]["pipelineVersion"] = 2
    payload.update(glossaryCapture=True, **change)
    with pytest.raises(ValidationError):
        TranslationRequest.model_validate(payload)


def test_legacy_paid_glossary_hash_is_identical_with_new_null_metadata():
    old = body(); old["options"].update(documentKind="fiction", layout="preserve"); old["options"]["glossary"] = [dict(source="Mary", target="玛丽")]
    parsed = TranslationRequest.model_validate(old).model_dump(mode="json")
    assert content_hash("translate", old) == content_hash("translate", parsed)
    query = dict(requestID="old-terms-0", source="Mary waved.", target="中文")
    assert content_hash("glossary", query) == content_hash("glossary", GlossaryRequest.model_validate(query).model_dump(mode="json"))


def test_capture_and_entity_identity_are_part_of_paid_request_hash():
    old = body(); old["options"]["pipelineVersion"] = 2
    changed = copy.deepcopy(old); changed["glossaryCapture"] = True
    assert content_hash("translate", old) != content_hash("translate", changed)
    old["options"]["glossary"] = [dict(source="Liz", target="丽兹", category="person", entityID="a")]
    changed = copy.deepcopy(old); changed["options"]["glossary"][0]["entityID"] = "b"
    assert content_hash("translate", old) != content_hash("translate", changed)


def test_entity_information_is_shared_with_language_and_proofreading_roles():
    payload = body(); payload.update(stage="linguist", draft="丽兹来了。", source="Liz arrived.")
    payload["options"]["quality"] = "deep"
    payload["options"]["glossary"] = [dict(source="Liz", target="丽兹", category="person", entityID="elizabeth", aliases=["Elizabeth"])]
    system = translation_messages(TranslationRequest.model_validate(payload))[0]["content"]
    assert "Elizabeth" in system and "elizabeth" in system
    assert "not interchangeable wording" in system and "preserve nicknames" in system


def test_entity_query_limits_output_reservation_and_capture_keeps_usage_pricing(settings):
    query = GlossaryRequest(requestID="q", source="Mary waved.", target="中文", mode="entities-v1", candidates=["Mary"])
    budget = TokenBudget.for_request(settings, glossary_messages(query), query.source, "glossary", entity_query=True)
    assert min(1536, settings.max_output_tokens) <= budget.desired_output_tokens <= min(3072, settings.max_output_tokens)
    assert budget.tokens_per_point == settings.tokens_per_point


def test_specialist_terms_allow_plural_grammar_without_matching_person_substrings():
    assert Term(source="design token", target="设计令牌", category="specialist").relevant_to("Use design tokens consistently.")
    assert Term(source="policy", target="政策", category="specialist").relevant_to("These policies apply.")
    assert not Term(source="Mary", target="玛丽", category="person").relevant_to("Maryland")
