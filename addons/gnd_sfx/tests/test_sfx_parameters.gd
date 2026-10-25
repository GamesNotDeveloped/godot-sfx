extends GutTest

## Parameters of the player, parameters derived from them, and events they start and stop

var runtime: SfxPlaybackRuntime
var bank: SfxBank


func before_each() -> void:
    runtime = SfxPlaybackRuntime.new()
    runtime.set_slot_capacity(4)
    bank = SfxBank.new()


func _declare(names: Array[StringName]) -> void:
    var parameters: Array[SfxParameter] = []
    for name in names:
        var parameter := SfxParameter.new()
        parameter.name = name
        parameters.append(parameter)
    bank.parameters = parameters


func _derive(name: StringName, expression: String, inputs: PackedStringArray, filter := SfxDerivedParameter.NONE, time_constant := 0.1) -> void:
    var derived := SfxDerivedParameter.new()
    derived.name = name
    derived.expression = expression
    derived.inputs = inputs
    derived.filter = filter
    derived.time_constant = time_constant
    var all := bank.derived_parameters
    all.append(derived)
    bank.derived_parameters = all


## An event of one clip started and stopped by `parameter` (see SfxParameterTrigger)
func _triggered(name: StringName, parameter: StringName, mode: SfxParameterTrigger.Mode, loop := false) -> SfxParameterTrigger:
    var trigger := SfxParameterTrigger.new()
    trigger.parameter = parameter
    trigger.mode = mode
    var event := SfxTestFixtures.make_event(name, [SfxTestFixtures.make_clip(0.0, 1.0, loop)])
    event.triggers = [trigger]
    var events := bank.events
    events.append(event)
    bank.events = events
    return trigger


func _feed(name: StringName, value: float, delta := 0.0) -> void:
    runtime.set_parameter(name, value)
    runtime.update(delta)


func _plays(name: StringName) -> int:
    return runtime.get_instance_ids(name).size()


func test_player_parameter_drives_every_event_of_the_bank() -> void:
    _declare([&"speed"])
    var event := SfxTestFixtures.make_event(&"engine")
    event.automations = [SfxTestFixtures.make_automation(&"speed", 0.0, 100.0, 10.0)]
    runtime.set_bank(bank)
    runtime.play(event)
    assert_eq(runtime.get_debug_voices().size(), 0, "Below the clip's range")
    _feed(&"speed", 20.0)
    assert_eq(runtime.get_debug_voices().size(), 1, "The player's value reaches the event")
    runtime.play(event, 0.0, {&"speed": 5.0})
    runtime.update(0.0)
    var voices_of_second := 0
    for voice in runtime.get_debug_voices():
        voices_of_second += 1 if voice.instance_id == runtime.get_instance_ids(&"engine")[1] else 0
    assert_eq(voices_of_second, 0, "An instance's own value wins over the player's")


func test_parameter_values_set_the_raw_parameters_in_order() -> void:
    _declare([&"speed", &"pressure", &"rpm"])
    _derive(&"sum", "speed + pressure + rpm", ["speed", "pressure", "rpm"])
    runtime.set_bank(bank)
    runtime.set_parameter_values(PackedFloat64Array([1.0, 2.0]))
    runtime.update(0.0)
    assert_eq([runtime.get_parameter(&"speed"), runtime.get_parameter(&"pressure"), runtime.get_parameter(&"rpm")], [1.0, 2.0, 0.0])
    assert_eq(runtime.get_parameter(&"sum"), 3.0, "Only what changed is evaluated, and all of it is")


func test_undeclared_parameter_is_refused() -> void:
    runtime.set_bank(bank)
    assert_false(runtime.set_parameter(&"nope", 1.0))


func test_derived_expression_of_several_parameters() -> void:
    _declare([&"a", &"b"])
    _derive(&"sum", "a * 2 + b", ["a", "b"])
    runtime.set_bank(bank)
    runtime.set_parameter(&"a", 1.0)
    _feed(&"b", 3.0)
    assert_eq(runtime.get_parameter(&"sum"), 5.0)


func test_smoothed_parameter_follows_with_its_time_constant() -> void:
    _declare([&"x"])
    _derive(&"smooth", "x", ["x"], SfxDerivedParameter.SMOOTH, 0.1)
    runtime.set_bank(bank)
    runtime.update(0.0)
    _feed(&"x", 1.0, 0.1)
    assert_almost_eq(runtime.get_parameter(&"smooth"), 1.0 - exp(-1.0), 0.001)
    assert_eq(runtime.get_next_wake(), runtime.get_clock(), "Unsettled, it is ticked every frame")
    for _index in range(50):
        runtime.update(0.1)
    assert_eq(runtime.get_parameter(&"smooth"), 1.0)
    assert_true(is_inf(runtime.get_next_wake()), "Settled, it sleeps")


func test_derivative_is_change_per_second() -> void:
    _declare([&"pressure"])
    _derive(&"rate", "pressure", ["pressure"], SfxDerivedParameter.DERIVATIVE)
    runtime.set_bank(bank)
    _feed(&"pressure", 0.0, 0.1)
    _feed(&"pressure", 1.0, 0.5)
    assert_almost_eq(runtime.get_parameter(&"rate"), 2.0, 0.0001)
    runtime.update(0.5)
    assert_eq(runtime.get_parameter(&"rate"), 0.0, "A still value has no rate")


func test_expression_reads_its_previous_value_and_delta() -> void:
    _declare([&"target"])
    _derive(&"slewed", "previous + clamp(target - previous, -0.2 * delta, 0.4 * delta)", ["target"])
    runtime.set_bank(bank)
    _feed(&"target", 1.0, 1.0)
    assert_almost_eq(runtime.get_parameter(&"slewed"), 0.4, 0.0001, "Rises at 0.4 per second")
    runtime.update(1.0)
    runtime.update(1.0)
    assert_almost_eq(runtime.get_parameter(&"slewed"), 1.0, 0.0001)
    _feed(&"target", 0.0, 1.0)
    assert_almost_eq(runtime.get_parameter(&"slewed"), 0.8, 0.0001, "Falls at 0.2 per second")


func test_gate_starts_and_stops_with_hysteresis() -> void:
    _declare([&"gain"])
    var trigger := _triggered(&"squeal", &"gain", SfxParameterTrigger.GATE, true)
    trigger.on_threshold = 0.075
    trigger.off_threshold = 0.05
    runtime.set_bank(bank)
    _feed(&"gain", 0.06)
    assert_false(runtime.is_playing(&"squeal"), "Below the start threshold")
    _feed(&"gain", 0.08)
    assert_true(runtime.is_playing(&"squeal"), "Above it")
    _feed(&"gain", 0.06)
    assert_true(runtime.is_playing(&"squeal"), "Between the thresholds it holds")
    _feed(&"gain", 0.04)
    assert_false(runtime.is_playing(&"squeal"), "Below the stop threshold")


func test_cross_fires_in_its_direction() -> void:
    _declare([&"p"])
    var up := _triggered(&"up", &"p", SfxParameterTrigger.CROSS)
    up.on_threshold = 1.0
    up.direction = SfxParameterTrigger.UP
    var down := _triggered(&"down", &"p", SfxParameterTrigger.CROSS)
    down.on_threshold = 1.0
    down.direction = SfxParameterTrigger.DOWN
    runtime.set_bank(bank)
    runtime.update(0.0)
    _feed(&"p", 2.0)
    assert_eq([_plays(&"up"), _plays(&"down")], [1, 0])
    _feed(&"p", 0.0)
    assert_eq([_plays(&"up"), _plays(&"down")], [1, 1])


func test_step_respects_its_minimum_interval() -> void:
    _declare([&"p"])
    var step := _triggered(&"click", &"p", SfxParameterTrigger.STEP)
    step.min_interval = 0.5
    runtime.set_bank(bank)
    runtime.update(0.0)
    _feed(&"p", 1.0)
    _feed(&"p", 2.0, 0.1)
    assert_eq(_plays(&"click"), 1, "A step within min_interval of the last fire is skipped")
    _feed(&"p", 3.0, 0.6)
    assert_eq(_plays(&"click"), 2)


func test_every_fires_per_step_of_travel() -> void:
    _declare([&"distance"])
    var joints := _triggered(&"clatter", &"distance", SfxParameterTrigger.EVERY)
    joints.step = 25.0
    runtime.set_bank(bank)
    runtime.update(0.0)
    for distance in [10.0, 20.0, 30.0]:
        _feed(&"distance", distance)
    assert_eq(_plays(&"clatter"), 1, "One rail length run")
    for distance in [40.0, 50.0]:
        _feed(&"distance", distance)
    assert_eq(_plays(&"clatter"), 2, "The remainder carries over")


func test_exclusive_trigger_skips_while_its_event_plays() -> void:
    _declare([&"p"])
    var step := _triggered(&"exclusive", &"p", SfxParameterTrigger.STEP)
    step.exclusive = true
    runtime.set_bank(bank)
    runtime.update(0.0)
    _feed(&"p", 1.0)
    _feed(&"p", 2.0)
    assert_eq(_plays(&"exclusive"), 1, "The second fire waits for nothing - it is dropped")


func test_gate_resumes_past_the_opening_after_a_cut() -> void:
    _declare([&"on"])
    var trigger := _triggered(&"horn", &"on", SfxParameterTrigger.GATE)
    trigger.on_threshold = 0.5
    trigger.resume_offset = 0.3
    var event: SfxEvent = bank.events[0]
    var opening: SfxClip = event.clips[0]
    opening.length = 0.3
    var loop := SfxTestFixtures.make_clip(0.3, 1.0, true)
    event.clips = [opening, loop]
    runtime.set_bank(bank)
    _feed(&"on", 1.0)
    assert_eq(runtime.get_debug_voices()[0].clip, opening, "Opened, it starts from its opening")
    runtime.clear()
    runtime.update(0.0)
    assert_eq(runtime.get_debug_voices().size(), 1)
    assert_eq(runtime.get_debug_voices()[0].clip, loop, "Back from a cut, it starts at resume_offset")


func test_latched_automation_keeps_the_chunk_chosen_at_start() -> void:
    var automation := SfxTestFixtures.make_automation(&"speed", 0.0, 2.0, 0.0)
    automation.latch_on_start = true
    var slow: SfxClip = automation.clips[0]
    slow.length = 1.0
    var fast := SfxTestFixtures.make_clip(1.0)
    fast.length = 1.0
    automation.clips = [slow, fast]
    var event := SfxTestFixtures.make_event(&"clatter")
    event.automations = [automation]
    runtime.play(event, 0.0, {&"speed": 0.5})
    runtime.modulate(event.name, {&"speed": 1.5})
    runtime.update(0.0)
    assert_eq(runtime.get_debug_voices().size(), 1)
    assert_eq(runtime.get_debug_voices()[0].clip, slow, "The chunk chosen at start stays")
    runtime.handle_slot_finished(0)
    runtime.update(0.0)
    assert_false(runtime.is_playing(event.name), "The one-shot ends with its chunk")


func test_player_exposes_parameters_as_properties() -> void:
    _declare([&"speed"])
    var player := SfxPlayer.new()
    player.bank = bank
    add_child_autoqfree(player)
    player.set("parameters/speed", 42.0)
    assert_eq(player.get("parameters/speed"), 42.0)
    assert_eq(player.get_parameter(&"speed"), 42.0)
    var names := player.get_property_list().map(func(property): return property.name)
    assert_has(names, "parameters/speed")


func test_cut_player_ignores_play_and_restarts_its_gates() -> void:
    _declare([&"on"])
    _triggered(&"cab", &"on", SfxParameterTrigger.GATE, true).on_threshold = 0.5
    var player := SfxPlayer.new()
    player.bank = bank
    add_child_autoqfree(player)
    player.cut = true
    player.set_parameter(&"on", 1.0)
    await _wait_frames(3)
    assert_false(player.is_playing(&"cab"), "A cut player starts nothing")
    player.cut = false
    await _wait_frames(3)
    assert_true(player.is_playing(&"cab"), "Back, its open gate starts the event")


func _wait_frames(count: int) -> void:
    for _index in range(count):
        await get_tree().process_frame
