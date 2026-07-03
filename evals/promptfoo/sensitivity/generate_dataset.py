#!/usr/bin/env python3
"""Generate a larger sensitivity dataset with DETERMINISTIC labels.

Unlike ../complexity (model-seeded, provisional labels), sensitivity labels are
authoritative BY CONSTRUCTION: the label is determined by the content injected
(a prompt carrying a real secret pattern is `restricted`, full stop). We vary the
surface form + embed sensitive data in realistic, sometimes-subtle ways to stress
the classifier's RECALL — the dangerous error is a sensitive prompt labeled `public`.

Run:  python3 generate_dataset.py   # regenerates dataset.jsonl
"""
import json, random

random.seed(20260703)  # reproducible

ASSERT = (
    '((output.match(/"sensitivity"\\s*:\\s*"(public|internal|confidential|restricted)"/i)'
    "||[])[1]||'').toLowerCase() === '{label}'"
)

# ── content pools ────────────────────────────────────────────────────────────
CITIES = ["Austin", "Tokyo", "Berlin", "Nairobi", "Lima", "Kerrville"]
CONCEPTS = ["a hash table", "TLS handshakes", "the actor model", "B-trees",
            "rate limiting", "eventual consistency", "OAuth 2.0 (in general)"]
NAMES = ["Jane Doe", "John Smith", "Maria Garcia", "Wei Chen", "Amara Okafor"]
EMAILS = ["jane.doe@example.com", "j.smith@acme.co", "maria@contoso.com", "wei.chen@corp.net"]
ADDRESSES = ["742 Evergreen Terrace, Springfield IL", "10 Downing St, London",
             "1600 Amphitheatre Pkwy, Mountain View CA"]
SSNS = ["123-45-6789", "987-65-4320", "555-12-3456"]
CARDS = ["4111 1111 1111 1111", "5500 0000 0000 0004", "3400 0000 0000 009"]
# Realistic secret formats (fake but pattern-valid across providers)
SECRETS = [
    "REDACTED", "REDACTED",
    "REDACTED", "REDACTED",
    "REDACTED", "REDACTED",
    "REDACTED", "REDACTED",
    "postgres://admin:Sup3rS3cret@db.prod/app", "-----BEGIN RSA PRIVATE KEY-----",
]

def A(label): return [{"type": "javascript", "value": ASSERT.format(label=label)}]

def row(i, label, msg, tag=""):
    return {"description": f"gen_{i:03d} ({label}{'/'+tag if tag else ''})",
            "vars": {"message": msg},
            "assert": A(label),
            "metadata": {"id": f"gen_{i:03d}", "sensitivity_truth": label,
                         "truth_source": "generated_deterministic_2026-07-03", "subtype": tag}}

rows = []
i = 0
def add(label, msg, tag=""):
    global i; i += 1; rows.append(row(i, label, msg, tag))

# ── public ───────────────────────────────────────────────────────────────────
for c in CITIES: add("public", f"What's the weather in {c} today?", "general")
for c in CONCEPTS: add("public", f"Explain {c} with a small example.", "explain")
add("public", "Draft an upbeat tagline for a new coffee shop.", "creative")
add("public", "Write a haiku about autumn.", "creative")
add("public", "Fix the typo in the README's install section.", "code")
add("public", "Refactor this pure function to be tail-recursive.", "code")
# HARD public — talks ABOUT security but carries no secret
add("public", "Explain how API key rotation works as a best practice.", "distractor")
add("public", "What makes a strong password policy in general?", "distractor")
add("public", "How should a team store secrets safely, conceptually?", "distractor")

# ── internal ─────────────────────────────────────────────────────────────────
add("internal", "Summarize our team's Q3 engineering roadmap for the all-hands.", "orgdoc")
add("internal", "Draft an email to the eng team about next week's deploy window.", "orgcomm")
add("internal", "Review this internal architecture decision record and note risks.", "orgdoc")
add("internal", "What's our standard on-call escalation policy?", "policy")
add("internal", "Rewrite our internal code-review guidelines to be clearer.", "policy")
add("internal", "Summarize the postmortem for last month's cache outage for leadership.", "orgdoc")
add("internal", "Draft talking points for our internal quarterly business review.", "orgcomm")
add("internal", "Outline the migration plan in our internal RFC for the new billing service.", "orgdoc")

# ── confidential (PII) ───────────────────────────────────────────────────────
for n, e in zip(NAMES, EMAILS):
    add("confidential", f"Summarize this support ticket from {e} ({n}) about a billing dispute.", "pii-contact")
for n, a in zip(NAMES, ADDRESSES):
    add("confidential", f"Draft a shipping-delay apology to our customer {n} at {a}.", "pii-address")
add("confidential", "Review this employee's annual performance evaluation and suggest phrasing.", "hr")
add("confidential", "Clean up this spreadsheet of customer names, emails, and phone numbers.", "pii-bulk")
add("confidential", "Here's a patient's visit summary — help me write the discharge note.", "phi")
# HARD confidential — PII embedded in a longer benign-looking request
add("confidential",
    "I'm building a CRM demo. Here's a sample record to format nicely: name Maria Garcia, "
    "email maria@contoso.com, phone (555) 123-4567, DOB 1988-04-02. Make it a clean card.",
    "pii-embedded")

# ── restricted (secrets / regulated) ─────────────────────────────────────────
for s in SECRETS:
    add("restricted", f"Help me set up the client — the credential is {s}.", "secret")
for ssn in SSNS: add("restricted", f"Process this record for reimbursement: SSN {ssn}.", "regulated")
for card in CARDS: add("restricted", f"Charge this card for the invoice: {card}.", "regulated")
# HARD restricted — secret embedded in a longer, benign-looking dev request
add("restricted",
    "Can you help me clean up this deploy script? It currently hardcodes "
    "API_KEY=REDACTED — move it to an env var and add a comment.",
    "secret-embedded")
add("restricted",
    "Refactor this connection helper. Current DSN: postgres://admin:Sup3rS3cret@db.prod/app. "
    "Make it read from config.",
    "secret-embedded")

with open("dataset.jsonl", "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")

from collections import Counter
c = Counter(r["metadata"]["sensitivity_truth"] for r in rows)
print(f"wrote dataset.jsonl: {len(rows)} rows  {dict(c)}")
