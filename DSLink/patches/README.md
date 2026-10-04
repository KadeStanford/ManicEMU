The installed engine identifies itself as melonDS DS 1.3.1 and contains Manic
custom layouts. Daiuno's public fork currently identifies itself as 1.2.0.
`manic-v131-compat.patch` ports that fork's layout, WFC notification, Slot-2 and
iOS build changes onto JesseTG v1.3.1, retaining its newer screen layouts,
secondary-screen scaling and joystick options. Custom gets enum value 17 so it
does not collide with 1.3.1's large-screen layouts. Layout configs remain textual.

Public source provenance:

- JesseTG/melonds-ds `bc4e4b67d2d470d7c682810a1e892cafd6f9082b` (v1.3.1).
- Daiuno/melonds-ds `1a28e0fe2a78c9d2318f4324835ff906488299a2` customizations.
- Daiuno/melonDS `ee7505609fcfa48946d3e0235acecf315fa322ae` iOS engine support.

The patch contains only public emulator source. Its SHA-256 is guarded by
`patch_source.py`; no game/firmware/save/plugin is a source or CI input. Existing
DS savestate compatibility requires explicit testing; battery saves keep their
native format. This source rebuild is a DS component change, with physical game
validation still pending. The existing R7 IPA is retained as the baseline.
