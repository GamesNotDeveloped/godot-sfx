Recurring mistakes to avoid in this repo:

- In GDScript, `maxf()` and `minf()` take exactly 2 arguments. Never chain 3 arguments in one call.
- After changing `TimelineView` layout, always re-check waveform geometry and lane widths in the active tab.
- Test changes with `godot --path demo --headless --quit` before replying.
- NEVER use "a != b". Use "not a == b" instead. ALWAYS
- NEVER use "if not (obj.prop == null)". Use "if obj.prop instead. ALWAYS
- NEVER use "x == null" or "x != null" for Object/Resource nullity checks
  (this includes RefCounted, Node, Resource, and any script class). Use
  "if x" / "if not x" instead - Godot objects are falsy when null or freed.
- NEVER wrap a String/StringName in String(x).is_empty() (or
  "not x.is_empty()") just to check whether it's empty. An empty
  String/StringName is already falsy - use "if x" / "if not x" directly.
  Only use String(x) when you actually need type coercion (e.g. building
  a PackedStringArray of a declared String type from a mixed source, or
  formatting), never purely to call .is_empty()/.length() on it.
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

* REQUIRED, ABSOLUTE: **a server is a singleton, never a class of static functions** - a C++
  Engine singleton or a GDScript autoload its plugin adds, never a `class_name` of `static func`s
  and `static var`s; none is added to such a class, one found is reported - see `CODE_STYLE.md`
* REQUIRED, ABSOLUTE: **nothing is loaded in a constructor, and no lazy cache stands in for it**:
  whoever makes or owns an object hands it what it needs through an explicit API (`*_set_*`) - see
  `CODE_STYLE.md`
