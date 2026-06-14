Recurring mistakes to avoid in this repo:

- In GDScript, `maxf()` and `minf()` take exactly 2 arguments. Never chain 3 arguments in one call.
- After changing `TimelineView` layout, always re-check waveform geometry and lane widths in the active tab.
- Test changes with `godot --path demo --headless --quit` before replying.
- NEVER use "a != b". Use "not a == b" instead. ALWAYS
- NEVER use "if not (obj.prop == null)". Use "if obj.prop instead. ALWAYS
- make code compact. very compact.
- avoid generating too much sanity checks
- keep code paths simple
- keep lines count as small as possible
- General rule: KISS - keep it simple, stupid!
- General rule: DRY - do not repeat!!!!
- NEVER use preload("script.gd") instead of class names. ALWAYS use
  declared class names!
- every UI component should have it's public interface and design saved
  in TSCN file. UI component should work standalone, without relying on
  the parents/others structure
