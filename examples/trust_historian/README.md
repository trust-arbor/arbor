# Composed public authority / Trust / Historian / SQL fixture

This normal OTP consumer owns its private Repo, Phoenix.PubSub and provisioner.
The nine canonical applications own their actual production modules and trees;
there are no Kernel Runtime, product Host, Signals or OIDC applications. Config
uses explicit nil runtime/observation/sync ports, real durable SQL and canonical
Trust approval/grant-owner and Historian puller descriptors. This is a single-node
composition proof, not current M2 product-release boot evidence.

The fixture explicitly selects Main's complete Kernel-owned persistence contract
set (Record, Revision, Filter and AppendOperation). Application entry verifies the
exact captured binding before creating directories or starting the Repo or any
owners. Trust's historical Record identity is preserved on acknowledged SQL writes
and fresh-VM recovery; there is no struct conversion or contract fallback.

The explicit install stage runs public SQL migrations before canonical roots.
Write drives the real public Core first-install/operator protocol and
public signatures, actor-authorized grants/delegation, replay/forgery denials and
nonce/use/rate checks, then the Trust and Historian proofs. Fresh VMs recover,
narrow and revoke authority, prove remaining live identities/keys deny revoked
scope, exercise actual SQL delivery/refusal/lost ACK, and reread public receipts.
Tokens remain within the admitted provisioner process. A separate caller-held
operator key is the documented first-install route; no Core-held private key is
read or bypassed. The invocation sink first delegates the real durable Historian
API and only then writes an fsynced private proof transcript.

Source/API review and strict compilation are required for the Trust/Historian
proof methods. Missing methods fail compilation and cannot be skipped.
A dedicated 3600-second phase drives 2300 real operator-authorized grant/revoke
pairs and checks the existing >=4096 retirement requirement. Namespace-only
rollback and wrong-content conflicts use separate copied state branches; their
non-quiescent evidence cannot replace the actual predecessor version rollback.
Each phase requires a retained execution receipt for the specific acceptance
attempt. Source and build metadata alone cannot satisfy these gates.
