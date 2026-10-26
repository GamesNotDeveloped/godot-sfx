extends GutTest

## A new event mixes through its "Master" track (#4: the C++ port left it null)


func test_a_new_event_has_its_master_track() -> void:
    var event: SfxEvent = SfxEvent.new()
    assert_not_null(event.master_track)
    assert_eq(event.master_track.track_name, &"Master")
