"""Local operator tools. Never exposed as web endpoints or user-controlled refunds."""
import argparse
import json
from pathlib import Path
import time

from .billing import TokenUsage
from .ledger import Ledger, ServiceError


def main():
    parser = argparse.ArgumentParser(description="Audit and reconcile the BookLLM credit ledger")
    parser.add_argument("--database", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("pending")
    sub.add_parser("audit")
    refund = sub.add_parser("refund")
    refund.add_argument("--account", required=True)
    refund.add_argument("--request", required=True)
    refund.add_argument("--reason", required=True)
    refund.add_argument("--confirm-provider-failed", action="store_true")
    complete = sub.add_parser("complete")
    complete.add_argument("--account", required=True)
    complete.add_argument("--request", required=True)
    complete.add_argument("--result-json", required=True, help='Verified recovered result, e.g. {"text":"..."} or glossary array')
    complete.add_argument("--usage-json", help="Recovered provider usage file with prompt_tokens and completion_tokens; required for token-billed requests")
    args = parser.parse_args()
    if not Path(args.database).is_file():
        parser.error("Database does not exist")
    ledger = Ledger(args.database)
    if args.command == "pending":
        with ledger.connection() as db:
            rows = db.execute("SELECT account_id,request_id,status,cost,reserved_cost,billing_mode,prompt_tokens,completion_tokens,actual_equivalent_points,absorbed_points,operation,attempts,created_at,updated_at FROM requests WHERE status IN ('reserved','dispatched','uncertain') ORDER BY created_at").fetchall()
        print(json.dumps([dict(row) for row in rows], ensure_ascii=False, indent=2))
    elif args.command == "audit":
        with ledger.connection() as db:
            rows = db.execute("SELECT a.id,a.points,a.credit_debt,COALESCE((SELECT SUM(delta) FROM credit_events c WHERE c.account_id=a.id),0) AS point_events,COALESCE((SELECT SUM(delta) FROM debt_events d WHERE d.account_id=a.id),0) AS debt_events FROM accounts a").fetchall()
        mismatches = [dict(row) for row in rows if row["points"] != row["point_events"] or row["credit_debt"] != row["debt_events"]]
        print(json.dumps({"accounts": len(rows), "mismatches": mismatches}, indent=2))
        if mismatches:
            raise SystemExit(1)
    elif args.command == "refund":
        state = ledger.request_status(args.account, args.request)
        if time.time() - state["updatedAt"] < 360:
            parser.error("Stop affected workers and wait at least 360 seconds after last activity before reconciliation")
        if state["status"] in ("dispatched", "uncertain") and not args.confirm_provider_failed:
            parser.error("Verify the provider's outcome first; use --confirm-provider-failed only after investigation")
        if not args.reason.strip():
            parser.error("A reconciliation reason is required")
        if ledger.refund(args.account, args.request, allow_uncertain=True):
            with ledger.atomic() as db:
                ledger._event(db, args.account, 0, "operator_reconciliation", args.request + ":" + args.reason)
            print("Reservation refunded once. The original requestID may now be retried.")
        else:
            print("No change: this request is already completed or refunded.")
    elif args.command == "complete":
        response = json.loads(Path(args.result_json).read_text())
        with ledger.connection() as db:
            row = db.execute("SELECT operation,billing_mode FROM requests WHERE account_id=? AND request_id=?", (args.account, args.request)).fetchone()
        if row is None:
            parser.error("Request does not exist")
        if row["operation"] == "translate":
            if not isinstance(response, dict) or set(response) != {"text"} or not isinstance(response["text"], str) or not response["text"].strip() or len(response["text"]) > 60000:
                parser.error("Invalid recovered translated text")
        else:
            from pydantic import TypeAdapter
            from .models import Term
            response = [term.model_dump() for term in TypeAdapter(list[Term]).validate_python(response)]
            if len(response) > 60:
                parser.error("Too many recovered terms")
        usage = None
        if args.usage_json:
            try:
                usage = TokenUsage.from_provider(json.loads(Path(args.usage_json).read_text()))
            except (ValueError, OSError):
                parser.error("Invalid verified usage JSON")
        if row["billing_mode"] == "tokens" and usage is None:
            parser.error("Token-billed reconciliation requires the provider's verified --usage-json; do not substitute an estimate")
        ledger.complete(args.account, args.request, response, usage)
        print("Verified result recorded. Retrying the original requestID returns it without additional debit.")


if __name__ == "__main__":
    main()
