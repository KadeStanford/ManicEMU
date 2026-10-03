# FireRed party-list regression

Public source reference: [pret/pokefirered at 037335f](https://github.com/pret/pokefirered/tree/037335f4c725d7c9aecdac87066f2002b4bd7e14).
Only selected link routines and definitions were read. No ROM, game assets or
Nintendo BIOS was downloaded or included in the tests.

`src/cable_club.c:Task_StartWiredTrade` closes the existing overworld link with
`SetCloseLinkCallback`, then calls `CB2_StartCreateTradeMenu` after remote players
disappear. `src/trade.c:CB2_CreateTradeMenu` sets `LINKTYPE_TRADE_CONNECTING` and
calls `OpenLink`. `src/link.c:OpenLink` calls `ResetSerial` (Enable/Disable) and
`InitLink` (Enable). `LinkMain1` disables once more, waits five core frames, and
enables for a new handshake. `DisableSerial` writes SIOCNT=2000; `EnableSerial`
writes 2000 then 6003. `SetCloseLinkCallback` sends 5FFF, which is shared with
normal endings. Checking that command alone would still break party entry.

`BufferTradeParties` requests three 200-byte blocks. Synthetic tests supply
deterministic arbitrary bytes, forwarding all INIT_BLOCK/CONT_BLOCK halfwords
through independent real gpSP processes and delayed, fragmented loopback TCP.
They compare every delivered halfword in both directions. They do not decode
Pokemon party structures or execute FireRed's trade/evolution/save logic.

`CB_FadeToStartTrade` closes with reason 32; `trade_scene.c` reopens with
LINKTYPE_TRADE_DISCONNECTED. `CB2_SaveAndEndTrade` uses standby barriers and a
close before returning to the saved menu callback. Menu cancellation uses close
reason 12 before returning to the multiplayer field. Battle entry similarly
closes the overworld link before initialization. The trace exercises these
handoffs and ordinary final idle cleanup; synthetic SRAM mutation stands in for
a changed battery save, not an actual traded Pokemon.

Baseline reproduction: commit f2215ec3813ccae478ded45edda8c5bd0ff6fb1a adds the trace
without changing v0.3's implementation. In [run 37099879237](https://github.com/KadeStanford/ManicEMU/actions/runs/37099879237)
the existing three tests passed; `firered_transitions` failed at the first
temporary hardware close with phase 8 (CLOSING) and one premature save flush.
This establishes a reproducible implementation defect consistent with the
reported party-list error, rather than a screenshot-only diagnosis.

v0.4 retains the same paired session across hardware toggles. Finalization uses
bilateral close intent, acknowledged OFF notifications, a cancellable 180-frame
quiet period on each core and an ordered QUIET barrier for each OFF generation.
Tests cover reopen at 179 frames, a slower peer reopening after the faster peer
became quiet-ready, missing ACKs, suspension, repeated reset toggles and final
save persistence. The window is a bounded heuristic: transitions that keep both
games completely idle longer than this window are not established as safe.

Remaining physical checks: actual FireRed party rendering, Pokemon selection,
trade animation/evolution, post-trade menu and normal room exit; battery save
reloaded after app restart; Single/Double battle entry, win/loss/forfeit; genuine
Wi-Fi interruption and bilateral recovery. The simulator runs a stub frontend,
not the original Manic executable. No signing or device installation is automated.
