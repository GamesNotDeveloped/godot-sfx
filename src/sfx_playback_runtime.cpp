#include "sfx_playback_runtime.hpp"

#include <godot_cpp/classes/audio_stream_generator.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>

using namespace godot;

static constexpr double NEVER = INFINITY;

static double curve_duration(const Ref<Curve> &p_curve) {
    return p_curve.is_valid() ? MAX(p_curve->get_max_domain() - p_curve->get_min_domain(), 0.0) : 0.0;
}

static double stream_length(const Ref<AudioStream> &p_stream) {
    return p_stream.is_valid() ? MAX(p_stream->get_length(), 0.0) : 0.0;
}

template <class T> static bool has(const LocalVector<T> &p_vector, const T &p_value) {
    return p_vector.find(p_value) != -1;
}

// --- Adsr --------------------------------------------------------------------------------------

void SfxPlaybackRuntime::Adsr::enter(bool p_enabled, double p_attack, double p_decay) {
    elapsed = 0.0;
    stage = !p_enabled ? ADSR_SUSTAIN : p_attack > 0.0 ? ADSR_ATTACK : p_decay > 0.0 ? ADSR_DECAY : ADSR_SUSTAIN;
}

void SfxPlaybackRuntime::Adsr::advance(double p_delta, bool p_enabled, double p_attack, double p_decay, double p_release) {
    if (!p_enabled) {
        stage = ADSR_SUSTAIN;
        elapsed = 0.0;
        return;
    }
    elapsed += p_delta;
    double length = stage == ADSR_ATTACK ? p_attack : stage == ADSR_DECAY ? p_decay : p_release;
    if (moving() && (length <= 0.0 || elapsed >= length)) {
        stage = stage == ADSR_ATTACK ? ADSR_DECAY : stage == ADSR_DECAY ? ADSR_SUSTAIN : ADSR_STOPPED;
        elapsed = 0.0;
    }
}

double SfxPlaybackRuntime::Adsr::gain(bool p_enabled, double p_attack, double p_decay, double p_sustain, double p_release) const {
    if (!p_enabled) {
        return 1.0;
    }
    double sustain = CLAMP(p_sustain, 0.0, 1.0);
    switch (stage) {
        case ADSR_ATTACK:
            return p_attack <= 0.0 ? 1.0 : CLAMP(elapsed / p_attack, 0.0, 1.0);
        case ADSR_DECAY:
            return p_decay <= 0.0 ? sustain : Math::lerp(1.0, sustain, CLAMP(elapsed / p_decay, 0.0, 1.0));
        case ADSR_RELEASE:
            return p_release <= 0.0 ? 0.0 : Math::lerp(release_start_gain, 0.0, CLAMP(elapsed / p_release, 0.0, 1.0));
        case ADSR_STOPPED:
            return 0.0;
        default:
            return sustain;
    }
}

bool SfxPlaybackRuntime::Adsr::begin_release(double p_gain, double p_release) {
    if (stage == ADSR_RELEASE || stage == ADSR_STOPPED) {
        return true;
    }
    release_start_gain = p_gain;
    stage = ADSR_RELEASE;
    elapsed = 0.0;
    return p_release > 0.0;
}

// --- Slot --------------------------------------------------------------------------------------

double SfxPlaybackRuntime::Slot::position(double p_now) const {
    double result = anchor_position + MAX(p_now - anchor_clock, 0.0) * pitch_scale;
    if (loop_end <= 0.0 || result < loop_end) {
        return result;
    }
    return looping ? loop_begin + Math::fmod(result - loop_begin, MAX(loop_end - loop_begin, CMP_EPSILON)) : loop_end;
}

void SfxPlaybackRuntime::Slot::swap_stream(const Ref<AudioStream> &p_stream) {
    stream = p_stream;
    looping = SfxStreamLoopSupport::is_looping(p_stream);
    Vector2 region = SfxStreamLoopSupport::get_loop_region(p_stream);
    loop_begin = looping ? region.x : 0.0;
    loop_end = looping ? region.y : stream_length(p_stream);
    dirty |= DIRTY_STREAM;
}

void SfxPlaybackRuntime::Slot::replay(double p_position, double p_now) {
    start_position = p_position;
    transport = TRANSPORT_PLAY;
    play_serial++;
    playing = true;
    anchor_position = p_position;
    anchor_clock = p_now;
    dirty |= DIRTY_TRANSPORT;
}

void SfxPlaybackRuntime::Slot::stop_playback() {
    transport = TRANSPORT_STOP;
    playing = false;
    anchor_position = 0.0;
    generator_stream_playback.unref();
    dirty |= DIRTY_TRANSPORT;
}

void SfxPlaybackRuntime::Slot::apply_gain(double p_volume_db) {
    if (!Math::is_equal_approx(volume_db, p_volume_db)) {
        volume_db = p_volume_db;
        dirty |= DIRTY_GAIN;
    }
}

void SfxPlaybackRuntime::Slot::apply_pitch(double p_pitch_scale, double p_now) {
    if (!Math::is_equal_approx(pitch_scale, p_pitch_scale)) {
        anchor(p_now);
        pitch_scale = p_pitch_scale;
        dirty |= DIRTY_PITCH;
    }
}

void SfxPlaybackRuntime::Slot::apply_spatial(const Ref<SfxSpatialConfig> &p_config, double p_unit_size) {
    if (spatial_override && spatial_position == p_config->position && spatial_attenuation_model == p_config->attenuation_model &&
            Math::is_equal_approx(spatial_unit_size, p_unit_size) && Math::is_equal_approx(spatial_max_distance, p_config->max_distance) &&
            Math::is_equal_approx(spatial_panning_strength, p_config->panning_strength)) {
        return;
    }
    spatial_override = true;
    spatial_position = p_config->position;
    spatial_attenuation_model = p_config->attenuation_model;
    spatial_unit_size = p_unit_size;
    spatial_max_distance = p_config->max_distance;
    spatial_panning_strength = p_config->panning_strength;
    dirty |= DIRTY_SPATIAL;
}

void SfxPlaybackRuntime::Slot::clear_spatial() {
    if (spatial_override) {
        spatial_override = false;
        dirty |= DIRTY_SPATIAL;
    }
}

void SfxPlaybackRuntime::Slot::reset(bool p_clear_stream, double p_now) {
    stop_playback();
    apply_pitch(1.0, p_now);
    apply_gain(0.0);
    clear_spatial();
    wants_generator = false;
    if (p_clear_stream) {
        swap_stream(Ref<AudioStream>());
    }
}

// --- Curves ------------------------------------------------------------------------------------

double SfxPlaybackRuntime::sample_time_curve(const Ref<Curve> &p_curve, double p_elapsed, bool p_from_end) {
    if (p_curve.is_null()) {
        return 1.0;
    }
    double duration = curve_duration(p_curve);
    if (duration <= 0.0) {
        return CLAMP(p_curve->sample(p_curve->get_max_domain()), 0.0, 1.0);
    }
    double elapsed = CLAMP(p_elapsed, 0.0, duration);
    return CLAMP(p_curve->sample(p_curve->get_min_domain() + (p_from_end ? duration - elapsed : elapsed)), 0.0, 1.0);
}

double SfxPlaybackRuntime::sample_automation_curve(const Ref<Curve> &p_curve, double p_value, double p_offset) {
    return p_curve.is_null() ? 1.0 : p_curve->sample(CLAMP(p_value - p_offset, p_curve->get_min_domain(), p_curve->get_max_domain()));
}

double SfxPlaybackRuntime::sample_automation_fade_out(const Ref<Curve> &p_curve, const Ref<SfxClip> &p_clip, double p_value) {
    if (p_curve.is_null()) {
        return 1.0;
    }
    if (p_clip->length > 0.0) {
        return sample_time_curve(p_curve, MAX(p_clip->offset + p_clip->length - p_value, 0.0), true);
    }
    double local = CLAMP(p_value - p_clip->offset, p_curve->get_min_domain(), p_curve->get_max_domain());
    return p_curve->sample(p_curve->get_min_domain() + (p_curve->get_max_domain() - local));
}

double SfxPlaybackRuntime::tail_start_position(double p_position, double p_end, bool p_was_looping) {
    if (p_end <= 0.0) {
        return 0.0;
    }
    if (p_was_looping) {
        return Math::fposmod(p_position, p_end);
    }
    return p_position >= p_end ? 0.0 : CLAMP(p_position, 0.0, p_end);
}

// --- Parameters --------------------------------------------------------------------------------

double SfxPlaybackRuntime::param(const Instance *p_instance, const StringName &p_name, double p_fallback) const {
    if (const double *value = p_instance ? p_instance->params.getptr(p_name) : nullptr) {
        return *value;
    }
    const int *index = parameter_index.getptr(p_name);
    return index ? parameter_values[*index] : p_fallback;
}

void SfxPlaybackRuntime::set_bank(const Ref<SfxBank> &p_bank) {
    parameter_index.clear();
    parameter_values.clear();
    parameter_dirty.clear();
    derived.clear();
    triggers.clear();
    raw_parameter_count = 0;
    if (p_bank.is_null()) {
        return;
    }
    for (const Ref<SfxParameter> &parameter : p_bank->parameters.items) {
        if (parameter.is_valid() && !parameter->name.is_empty() && !parameter_index.has(parameter->name)) {
            parameter_index[parameter->name] = parameter_values.size();
            parameter_values.push_back(parameter->default_value);
        }
    }
    raw_parameter_count = parameter_values.size();
    for (const Ref<SfxDerivedParameter> &resource : p_bank->derived_parameters.items) {
        if (resource.is_null() || resource->name.is_empty() || parameter_index.has(resource->name)) {
            continue;
        }
        Derived entry;
        entry.resource = resource;
        entry.expression.instantiate();
        PackedStringArray names = resource->inputs;
        names.append("previous");
        names.append("delta");
        if (entry.expression->parse(resource->expression, names) != OK) {
            ERR_PRINT(vformat("SfxDerivedParameter %s: %s", resource->name, entry.expression->get_error_text()));
            entry.expression.unref();
        }
        for (const String &input : resource->inputs) {
            const int *index = parameter_index.getptr(input);
            ERR_CONTINUE_MSG(!index, vformat("SfxDerivedParameter %s: unknown input %s", resource->name, input));
            entry.inputs.push_back(*index);
        }
        entry.arguments.resize(entry.inputs.size() + 2);
        entry.index = parameter_values.size();
        entry.settled = false;
        parameter_index[resource->name] = entry.index;
        parameter_values.push_back(0.0);
        derived.push_back(entry);
    }
    for (const Ref<SfxEvent> &event : p_bank->events.items) {
        if (event.is_null()) {
            continue;
        }
        event->prepare();
        for (const Ref<SfxParameterTrigger> &resource : event->triggers.items) {
            const int *index = resource.is_valid() ? parameter_index.getptr(resource->parameter) : nullptr;
            ERR_CONTINUE_MSG(!index, vformat("SfxEvent %s: a trigger reads an undeclared parameter", event->name));
            Trigger trigger;
            trigger.event = event;
            trigger.resource = resource;
            trigger.index = *index;
            triggers.push_back(trigger);
        }
    }
    parameter_dirty.resize(parameter_values.size());
    for (uint32_t i = 0; i < parameter_values.size(); i++) {
        mark_parameter(i);
    }
}

void SfxPlaybackRuntime::mark_parameter(int p_index) {
    parameter_dirty[p_index] = 1;
    parameters_changed = true;
}

bool SfxPlaybackRuntime::set_parameter(const StringName &p_name, double p_value) {
    const int *index = parameter_index.getptr(p_name);
    if (!index || *index >= raw_parameter_count) {
        return false;
    }
    if (parameter_values[*index] != p_value) {
        parameter_values[*index] = p_value;
        mark_parameter(*index);
    }
    return true;
}

// The bank's raw parameters in their declaration order, from the first: one call for all of them
void SfxPlaybackRuntime::set_parameter_values(const PackedFloat64Array &p_values) {
    for (int i = 0; i < MIN(int(p_values.size()), raw_parameter_count); i++) {
        if (parameter_values[i] != p_values[i]) {
            parameter_values[i] = p_values[i];
            mark_parameter(i);
        }
    }
}

double SfxPlaybackRuntime::get_parameter(const StringName &p_name) const {
    return param(nullptr, p_name, 0.0);
}

// A derived parameter is evaluated when one of its inputs changed or while it still moves; an
// automation is looked at again, and a trigger checked, only when its own parameter changed
void SfxPlaybackRuntime::update_parameters(double p_delta) {
    for (Derived &entry : derived) {
        bool due = !entry.settled;
        for (int input : entry.inputs) {
            due = due || parameter_dirty[input];
        }
        if (!due) {
            continue;
        }
        double &value = parameter_values[entry.index];
        double before = value;
        // straight into the array's own storage: one interface call, not one per argument
        Variant *arguments = &entry.arguments[0];
        for (uint32_t i = 0; i < entry.inputs.size(); i++) {
            arguments[i] = parameter_values[entry.inputs[i]];
        }
        arguments[entry.inputs.size()] = value;
        arguments[entry.inputs.size() + 1] = p_delta;
        double target = entry.expression.is_valid() ? double(entry.expression->execute(entry.arguments, nullptr, false, false)) : 0.0;
        switch (entry.resource->filter) {
            case SfxDerivedParameter::SMOOTH:
                if (!entry.has_previous) {
                    value = target;
                } else if (p_delta > 0.0) {
                    value += (target - value) * (1.0 - Math::exp(-p_delta / MAX(entry.resource->time_constant, CMP_EPSILON)));
                }
                entry.settled = Math::abs(target - value) <= 1e-6 * MAX(1.0, Math::abs(target));
                value = entry.settled ? target : value;
                break;
            case SfxDerivedParameter::DERIVATIVE:
                if (entry.has_previous && p_delta > 0.0) {
                    value = (target - entry.previous_input) / p_delta;
                }
                entry.settled = value == 0.0;
                break;
            default:
                // an expression of `previous` and `delta` keeps moving until it stops
                entry.settled = entry.has_previous && target == value;
                value = target;
        }
        if (!entry.has_previous || p_delta > 0.0) {
            entry.previous_input = target;
            entry.has_previous = true;
        }
        if (value != before) {
            mark_parameter(entry.index);
        }
    }
    if (!parameters_changed) {
        return;
    }
    for (const std::unique_ptr<Instance> &instance : instances) {
        for (const Ref<SfxAutomation> &automation : instance->event->automations.items) {
            const int *index = automation.is_valid() ? parameter_index.getptr(automation->parameter_name) : nullptr;
            instance->automation_refresh_pending = instance->automation_refresh_pending || (index && parameter_dirty[*index]);
        }
    }
    if (triggers_enabled) {
        fire_triggers();
    }
    memset(parameter_dirty.ptr(), 0, parameter_dirty.size());
    parameters_changed = false;
}

void SfxPlaybackRuntime::fire_triggers() {
    for (Trigger &trigger : triggers) {
        if (!parameter_dirty[trigger.index]) {
            continue;
        }
        const SfxParameterTrigger &resource = **trigger.resource;
        double value = parameter_values[trigger.index];
        double step = MAX(resource.step, CMP_EPSILON);
        double offset = 0.0;
        bool up = false, down = false;
        switch (resource.mode) {
            case SfxParameterTrigger::GATE:
                if (!trigger.open && value >= resource.on_threshold) {
                    trigger.open = true;
                    up = !is_playing(trigger.event->name);
                    offset = trigger.resume ? resource.resume_offset : 0.0;
                } else if (trigger.open && value < resource.off_threshold) {
                    trigger.open = false;
                    stop_event(trigger.event->name, false);
                }
                // a gate resumes only on the value it finds, not when it opens later
                trigger.resume = false;
                break;
            case SfxParameterTrigger::CROSS:
                up = trigger.has_previous && trigger.previous < resource.on_threshold && value >= resource.on_threshold;
                down = trigger.has_previous && trigger.previous >= resource.on_threshold && value < resource.on_threshold;
                break;
            case SfxParameterTrigger::STEP:
                up = trigger.has_previous && Math::floor(value / step) > Math::floor(trigger.previous / step);
                down = trigger.has_previous && Math::floor(value / step) < Math::floor(trigger.previous / step);
                break;
            case SfxParameterTrigger::EVERY:
                trigger.accumulated += trigger.has_previous ? Math::abs(value - trigger.previous) : 0.0;
                up = trigger.accumulated >= step;
                trigger.accumulated = up ? Math::fmod(trigger.accumulated, step) : trigger.accumulated;
                break;
        }
        trigger.previous = value;
        trigger.has_previous = true;
        bool fire = resource.mode == SfxParameterTrigger::GATE || resource.mode == SfxParameterTrigger::EVERY ? up
                : resource.direction == SfxParameterTrigger::UP                                         ? up
                : resource.direction == SfxParameterTrigger::DOWN                                       ? down
                                                                                                        : up || down;
        if (fire && clock - trigger.last_fire >= resource.min_interval && !(resource.exclusive && is_playing(trigger.event->name))) {
            trigger.last_fire = clock;
            start_instance(trigger.event, offset);
        }
    }
}

void SfxPlaybackRuntime::set_triggers_enabled(bool p_enabled) {
    if (p_enabled && !triggers_enabled) {
        // what moved while off is not a step: the edges start from the values found now, and a gate
        // found open - open before or opened meanwhile - starts past its opening (resume_offset), as
        // a sound activated out of range drops its opening bookend (MaSzyna's sound.cpp:364-371)
        for (Trigger &trigger : triggers) {
            trigger.has_previous = trigger.has_previous && trigger.resource->mode == SfxParameterTrigger::GATE;
            trigger.resume = trigger.resource->mode == SfxParameterTrigger::GATE;
            mark_parameter(trigger.index);
        }
    }
    triggers_enabled = p_enabled;
}

// --- Instances ---------------------------------------------------------------------------------

SfxPlaybackRuntime::~SfxPlaybackRuntime() {
    clear();
}

SfxPlaybackRuntime::Instance *SfxPlaybackRuntime::latest_instance(const StringName &p_name, bool p_playing_first) const {
    for (int pass = p_playing_first ? 0 : 1; pass < 2; pass++) {
        for (auto it = instances.rbegin(); it != instances.rend(); ++it) {
            if ((*it)->name == p_name && (pass == 1 || (*it)->status == STATUS_PLAYING)) {
                return it->get();
            }
        }
    }
    return nullptr;
}

SfxPlaybackRuntime::Instance *SfxPlaybackRuntime::start_instance(const Ref<SfxEvent> &p_event, double p_offset, const Dictionary &p_parameters) {
    if (!p_event->polyphony_enabled) {
        while (Instance *existing = latest_instance(p_event->name)) {
            stop_event_instance(existing, true);
        }
    }
    instances.push_back(std::make_unique<Instance>());
    Instance *instance = instances.back().get();
    instance->id = ++instance_counter;
    instance->event = p_event;
    instance->name = p_event->name;
    instance->playback_time = MAX(p_offset, 0.0);
    Array keys = p_parameters.keys();
    for (int64_t i = 0; i < keys.size(); i++) {
        instance->params[keys[i]] = p_parameters[keys[i]];
    }
    instance->adsr.enter(p_event->adsr_enabled, p_event->attack, p_event->decay);
    refresh_event_clips(instance, -1.0, instance->playback_time, false);
    refresh_automation_clips(instance);
    return instance;
}

void SfxPlaybackRuntime::play(const Ref<SfxEvent> &p_event, double p_offset, const Dictionary &p_parameters) {
    if (p_event.is_null()) {
        return;
    }
    p_event->prepare();
    start_instance(p_event, p_offset, p_parameters);
}

void SfxPlaybackRuntime::remove_instance(Instance *p_instance) {
    for (int i = int(voices.size()) - 1; i >= 0; i--) {
        if (i < int(voices.size()) && voices[i]->instance == p_instance) {
            stop_voice(i);
        }
    }
    for (auto it = instances.begin(); it != instances.end(); ++it) {
        if (it->get() == p_instance) {
            instances.erase(it);
            break;
        }
    }
    finished_pending = finished_pending || (voices.empty() && instances.empty());
}

void SfxPlaybackRuntime::stop_event_instance(Instance *p_instance, bool p_immediate) {
    if (p_immediate) {
        remove_instance(p_instance);
        return;
    }
    if (p_instance->status == STATUS_RELEASING) {
        return;
    }
    const SfxEvent &event = **p_instance->event;
    p_instance->status = STATUS_RELEASING;
    p_instance->release_time = 0.0;
    p_instance->adsr.release_start_gain = p_instance->adsr.gain(event.adsr_enabled, event.attack, event.decay, event.sustain, event.release);
    if (event.adsr_enabled && event.release > 0.0) {
        p_instance->adsr.stage = ADSR_RELEASE;
    } else {
        p_instance->adsr.stage = ADSR_SUSTAIN;
        for (int i = int(voices.size()) - 1; i >= 0; i--) {
            if (i < int(voices.size()) && voices[i]->instance == p_instance && !begin_voice_stop(voices[i].get())) {
                stop_voice(i);
            }
        }
    }
    p_instance->adsr.elapsed = 0.0;
    refresh_event_clips(p_instance, -1.0, 0.0, true);
}

bool SfxPlaybackRuntime::has_voices(const Instance *p_instance) const {
    for (const std::unique_ptr<Voice> &voice : voices) {
        if (voice->instance == p_instance) {
            return true;
        }
    }
    return false;
}

bool SfxPlaybackRuntime::has_pending_play_activity(const Instance *p_instance) const {
    if (has_voices(p_instance)) {
        return true;
    }
    for (const Ref<SfxClip> &clip : p_instance->event->clips.items) {
        if (clip.is_null()) {
            continue;
        }
        if (clip->trigger_mode == SfxClip::TRIGGER_SUSTAIN && !has(p_instance->triggered_sustain_clips, clip)) {
            return true;
        }
        if (clip->trigger_mode == SfxClip::TRIGGER_TIMELINE && !has(p_instance->triggered_event_clips, clip) &&
                clip->offset >= p_instance->playback_time) {
            return true;
        }
    }
    for (const Ref<SfxAutomation> &automation : p_instance->event->automations.items) {
        if (automation.is_null() || automation->parameter_name.is_empty() || (automation->latch_on_start && p_instance->automations_started)) {
            continue;
        }
        const LocalVector<Ref<SfxClip>> *triggered = p_instance->triggered_automation_clips.getptr(automation->parameter_name);
        for (const Ref<SfxClip> &clip : automation->clips.items) {
            if (clip.is_valid() && clip->trigger_mode == SfxClip::TRIGGER_TIMELINE && !(triggered && has(*triggered, clip))) {
                return true;
            }
        }
    }
    return false;
}

void SfxPlaybackRuntime::collect_finished_instances() {
    for (size_t i = 0; i < instances.size();) {
        Instance *instance = instances[i].get();
        bool finished = instance->status == STATUS_PLAYING ? !has_pending_play_activity(instance)
                                                          : instance->adsr.stage == ADSR_STOPPED || !has_voices(instance);
        if (finished) {
            remove_instance(instance);
        } else {
            i++;
        }
    }
    finished_pending = finished_pending || (voices.empty() && instances.empty());
}

void SfxPlaybackRuntime::update_instance(Instance *p_instance, double p_delta) {
    if (p_instance->automation_refresh_pending) {
        p_instance->automation_refresh_pending = false;
        refresh_automation_clips(p_instance);
    }
    double previous = p_instance->playback_time;
    double previous_release = p_instance->release_time;
    if (p_instance->status == STATUS_PLAYING) {
        p_instance->playback_time += p_delta;
        refresh_event_clips(p_instance, previous, p_instance->playback_time, false);
    } else if (p_instance->status == STATUS_RELEASING) {
        p_instance->playback_time += p_delta;
        p_instance->release_time += p_delta;
        refresh_event_clips(p_instance, previous_release, p_instance->release_time, true);
    }
    const SfxEvent &event = **p_instance->event;
    p_instance->adsr.advance(p_delta, event.adsr_enabled, event.attack, event.decay, event.release);
    if (p_instance->adsr.stage == ADSR_STOPPED) {
        stop_event_instance(p_instance, true);
    }
}

// Starts the timeline (or, while releasing, the sustain) clips whose offset the clock has passed
void SfxPlaybackRuntime::refresh_event_clips(Instance *p_instance, double p_previous, double p_current, bool p_sustain) {
    LocalVector<Ref<SfxClip>> &triggered = p_sustain ? p_instance->triggered_sustain_clips : p_instance->triggered_event_clips;
    for (const Ref<SfxClip> &clip : p_instance->event->clips.items) {
        if (clip.is_null() || clip->trigger_mode != (p_sustain ? SfxClip::TRIGGER_SUSTAIN : SfxClip::TRIGGER_TIMELINE) ||
                has(triggered, clip) || p_current < clip->offset) {
            continue;
        }
        // an instance started (or sought) at a position does not play a clip whose span on the
        // timeline is already over - FMOD's setTimelinePosition
        if (!p_sustain && p_previous < 0.0 && clip->length > 0.0 && p_current >= clip->offset + clip->length) {
            triggered.push_back(clip);
            continue;
        }
        if (start_voice(p_instance, clip)) {
            triggered.push_back(clip);
        }
    }
}

static bool automation_contains(const SfxAutomation &p_automation, const SfxClip &p_clip, double p_value) {
    bool ascending = p_automation.max_domain >= p_automation.min_domain;
    double end = ascending ? p_automation.max_domain : p_automation.min_domain;
    if (p_clip.length > 0.0) {
        end = ascending ? p_clip.offset + p_clip.length : p_clip.offset - p_clip.length;
    }
    return ascending ? p_value >= p_clip.offset && p_value <= end : p_value <= p_clip.offset && p_value >= end;
}

void SfxPlaybackRuntime::refresh_automation_clips(Instance *p_instance) {
    for (const Ref<SfxAutomation> &automation : p_instance->event->automations.items) {
        if (automation.is_null() || automation->parameter_name.is_empty() || (automation->latch_on_start && p_instance->automations_started)) {
            continue;
        }
        const StringName &name = automation->parameter_name;
        double value = param(p_instance, name, automation->min_domain);
        if (!p_instance->triggered_automation_clips.has(name)) {
            p_instance->triggered_automation_clips[name] = LocalVector<Ref<SfxClip>>();
        }
        for (const Ref<SfxClip> &clip : automation->clips.items) {
            if (clip.is_null() || clip->trigger_mode != SfxClip::TRIGGER_TIMELINE) {
                continue;
            }
            LocalVector<Ref<SfxClip>> &triggered = p_instance->triggered_automation_clips[name];
            Voice *voice = find_voice(p_instance, clip, name);
            if (automation_contains(**automation, **clip, value)) {
                if (!has(triggered, clip) && ((voice && !automation_voice_releasing(voice)) || start_voice(p_instance, clip, automation))) {
                    p_instance->triggered_automation_clips[name].push_back(clip);
                }
                continue;
            }
            triggered.erase(clip);
            if (voice && !automation_voice_releasing(voice)) {
                if (clip->cut) {
                    stop_automation_voice(voice);
                } else {
                    finish_automation_voice_on_end(voice);
                }
            }
        }
    }
    p_instance->automations_started = true;
}

// --- Voices ------------------------------------------------------------------------------------

int SfxPlaybackRuntime::find_voice_index(const Voice *p_voice) const {
    for (size_t i = 0; i < voices.size(); i++) {
        if (voices[i].get() == p_voice) {
            return int(i);
        }
    }
    return -1;
}

int SfxPlaybackRuntime::find_slot_voice(int p_slot, int64_t p_token) const {
    for (size_t i = 0; i < voices.size(); i++) {
        if (voices[i]->slot == p_slot && (p_token == -1 || voices[i]->slot_token == p_token)) {
            return int(i);
        }
    }
    return -1;
}

SfxPlaybackRuntime::Voice *SfxPlaybackRuntime::find_voice(const Instance *p_instance, const Ref<SfxClip> &p_clip, const StringName &p_automation) const {
    Voice *latest = nullptr;
    for (const std::unique_ptr<Voice> &voice : voices) {
        if (voice->instance == p_instance && voice->clip == p_clip && voice->automation_name == p_automation &&
                (!latest || voice->creation_order > latest->creation_order)) {
            latest = voice.get();
        }
    }
    return latest;
}

// A free slot, a new one while the pool may grow, or a stolen one: a releasing voice goes first,
// then a one-shot, and a loop only when nothing else is left - a stolen loop is not started again
// (its clip has already triggered), so a burst of one-shots would silence a running noise for good
int SfxPlaybackRuntime::acquire_slot() {
    for (uint32_t i = 0; i < slots.size(); i++) {
        if (find_slot_voice(i) == -1) {
            return i;
        }
    }
    if (int(slots.size()) < slot_capacity) {
        slots.push_back(Slot());
        return slots.size() - 1;
    }
    Voice *releasing = nullptr, *one_shot = nullptr, *oldest = nullptr;
    for (const std::unique_ptr<Voice> &voice : voices) {
        auto older = [&](Voice *p_other) { return !p_other || voice->creation_order < p_other->creation_order; };
        oldest = older(oldest) ? voice.get() : oldest;
        releasing = voice->instance->status == STATUS_RELEASING && older(releasing) ? voice.get() : releasing;
        one_shot = !SfxStreamLoopSupport::is_looping(voice->stream) && older(one_shot) ? voice.get() : one_shot;
    }
    Voice *victim = releasing ? releasing : one_shot ? one_shot : oldest;
    if (!victim) {
        return -1;
    }
    int slot = victim->slot;
    stop_voice(find_voice_index(victim));
    return slot;
}

double SfxPlaybackRuntime::voice_start_position(const Instance *p_instance, const Ref<SfxClip> &p_clip, const Ref<SfxAutomation> &p_automation,
        const Ref<AudioStream> &p_stream) const {
    double start = MAX(p_clip->stream_offset, 0.0);
    double length = stream_length(p_stream);
    if (p_automation.is_valid() && p_automation->phase_locked && p_automation->phase_period > 0.0) {
        double available = MAX(length - start, 0.0);
        if (available > 0.0) {
            double phase = Math::fposmod(p_instance->playback_time + p_clip->phase_offset, p_automation->phase_period);
            start += phase > available ? Math::fposmod(phase, available) : phase;
        }
    } else {
        if (p_automation.is_null() && p_clip->trigger_mode == SfxClip::TRIGGER_TIMELINE) {
            start += MAX(p_instance->playback_time - p_clip->offset, 0.0);
        }
        // every clip but a bookend carries the event's shift, as a fraction of the clip that starts:
        // emitters playing one recording in step comb-filter into a ring (MaSzyna's m_startoffset)
        double fraction = p_instance->event->start_fraction;
        if (fraction > 0.0 && !p_clip->bookend && p_clip->stream.is_valid()) {
            start += MAX(stream_length(p_clip->stream) - start, 0.0) * fraction;
        }
    }
    return length > 0.0 ? CLAMP(start, 0.0, length) : start;
}

static double voice_end_position(const SfxClip &p_clip, const Ref<AudioStream> &p_stream) {
    double length = stream_length(p_stream);
    return length > 0.0 && p_clip.length > 0.0 ? MIN(MAX(p_clip.stream_offset, 0.0) + p_clip.length, length) : length;
}

bool SfxPlaybackRuntime::start_voice(Instance *p_instance, const Ref<SfxClip> &p_clip, const Ref<SfxAutomation> &p_automation) {
    StringName automation_name = p_automation.is_valid() ? p_automation->parameter_name : StringName();
    if (Voice *existing = find_voice(p_instance, p_clip, automation_name)) {
        if (p_automation.is_valid()) {
            if (automation_voice_releasing(existing)) {
                restart_automation_voice(existing);
            } else {
                apply_voice_state(existing);
            }
        }
        return true;
    }
    int slot_index = acquire_slot();
    if (slot_index < 0 || p_clip->stream.is_null()) {
        return false;
    }
    bool generator = Object::cast_to<AudioStreamGenerator>(p_clip->stream.ptr());
    ERR_FAIL_COND_V_MSG(generator && p_clip->generator_playback.is_null(), false, "An AudioStreamGenerator clip requires generator_playback");
    Ref<AudioStream> stream = p_clip->stream;
    double start = voice_start_position(p_instance, p_clip, p_automation, stream);
    double end = voice_end_position(**p_clip, stream);
    start = end > 0.0 ? MIN(start, end) : start;

    Slot &slot = slots[slot_index];
    slot.apply_pitch(1.0, clock);
    slot.wants_generator = generator;
    voices.push_back(std::make_unique<Voice>());
    Voice *voice = voices.back().get();
    voice->slot = slot_index;
    voice->slot_token = ++slot.token;
    slot.swap_stream(stream);
    slot.replay(start, clock);
    voice->instance = p_instance;
    voice->clip = p_clip;
    voice->stream = stream;
    voice->stream_start = start;
    voice->stream_end = end;
    voice->truncated = end > 0.0 && end < stream_length(stream) - CMP_EPSILON;
    voice->automation = p_automation;
    voice->automation_name = automation_name;
    voice->creation_order = voice_counter++;
    voice->generator = generator ? Ref<SfxGeneratorPlayback>(p_clip->generator_playback) : Ref<SfxGeneratorPlayback>();
    Ref<SfxTrack> track = mixer_track(voice);
    voice->track_adsr.enter(track.is_valid() && track->adsr_enabled, track.is_valid() ? track->attack : 0.0, track.is_valid() ? track->decay : 0.0);
    apply_voice_state(voice);
    pump_generator(voice, 0.0);
    return true;
}

Ref<SfxTrack> SfxPlaybackRuntime::mixer_track(const Voice *p_voice) const {
    return p_voice->clip->track.is_valid() ? p_voice->clip->track : p_voice->instance->event->master_track;
}

double SfxPlaybackRuntime::mixer_gain(const Voice *p_voice) const {
    Ref<SfxTrack> track = mixer_track(p_voice);
    double gain = track.is_null() ? 1.0 : track->mute ? 0.0 : Math::db_to_linear(track->volume_db);
    if (track.is_valid() && track->solo) {
        return gain;
    }
    const SfxEvent &event = **p_voice->instance->event;
    bool solo = event.master_track.is_valid() && event.master_track->solo;
    for (const Ref<SfxTrack> &other : event.tracks.items) {
        solo = solo || (other.is_valid() && other->solo);
    }
    return solo ? 0.0 : gain;
}

bool SfxPlaybackRuntime::begin_track_release(Voice *p_voice) {
    Ref<SfxTrack> track = mixer_track(p_voice);
    if (track.is_null() || !track->adsr_enabled) {
        return false;
    }
    double gain = p_voice->track_adsr.gain(true, track->attack, track->decay, track->sustain, track->release);
    return p_voice->track_adsr.begin_release(gain, track->release);
}

double SfxPlaybackRuntime::automation_raw_gain(const Voice *p_voice) const {
    const SfxClip &clip = **p_voice->clip;
    double value = param(p_voice->instance, p_voice->automation_name, p_voice->automation->min_domain);
    double fade_in = CLAMP(sample_automation_curve(clip.fade_in_curve, value, clip.offset), 0.0, 1.0);
    double fade_out = CLAMP(sample_automation_fade_out(clip.fade_out_curve, p_voice->clip, value), 0.0, 1.0);
    return p_voice->automation->crossfade_mode == SfxAutomation::EQUAL_POWER ? Math::sqrt(fade_in) * Math::sqrt(fade_out) : fade_in * fade_out;
}

// Normalized against the other voices of the same automation of the same instance, so a crossfade
// keeps the group's amplitude (linear) or power (equal power)
double SfxPlaybackRuntime::automation_clip_gain(const Voice *p_voice) const {
    double raw = automation_raw_gain(p_voice);
    bool equal_power = p_voice->automation->crossfade_mode == SfxAutomation::EQUAL_POWER;
    double sum = 0.0;
    for (const std::unique_ptr<Voice> &other : voices) {
        if (other->automation.is_valid() && !automation_voice_releasing(other.get()) && other->instance == p_voice->instance &&
                other->automation_name == p_voice->automation_name) {
            double gain = automation_raw_gain(other.get());
            sum += equal_power ? gain * gain : gain;
        }
    }
    return sum <= 1.0 ? raw : equal_power ? raw / Math::sqrt(sum) : raw / sum;
}

void SfxPlaybackRuntime::apply_voice_state(Voice *p_voice) {
    Slot &slot = slots[p_voice->slot];
    const SfxClip &clip = **p_voice->clip;
    const Instance *instance = p_voice->instance;
    double clip_gain = 1.0, pitch = 1.0;
    if (p_voice->automation.is_valid()) {
        double value = param(instance, p_voice->automation_name, p_voice->automation->min_domain);
        if (automation_voice_releasing(p_voice)) {
            clip_gain = p_voice->automation_release_gain;
        } else {
            clip_gain = automation_clip_gain(p_voice);
            p_voice->automation_current_gain = clip_gain;
            p_voice->automation_release_gain = clip_gain;
        }
        pitch = sample_automation_curve(clip.pitch_curve, value, clip.offset) * sample_automation_curve(p_voice->automation->pitch_curve, value, 0.0);
    } else {
        double position = slot.playing ? slot.position(clock) : 0.0;
        double local = MAX(position - p_voice->stream_start, 0.0);
        double end = p_voice->stream_end > 0.0 ? p_voice->stream_end : stream_length(p_voice->stream);
        clip_gain = sample_time_curve(clip.fade_in_curve, local, false);
        if (p_voice->stopping) {
            clip_gain *= sample_time_curve(clip.fade_out_curve, MAX(p_voice->stop_fade - p_voice->stop_elapsed, 0.0), true);
        } else if (!slot.looping && end > 0.0) {
            // a loop has no end to fade out towards - only its stop fades it
            clip_gain *= sample_time_curve(clip.fade_out_curve, MAX(end - position, 0.0), true);
        }
        pitch = clip.pitch_curve.is_valid() ? clip.pitch_curve->sample(clip.pitch_curve->get_min_domain() + CLAMP(local, 0.0, curve_duration(clip.pitch_curve))) : 1.0;
    }

    double parameter_gain = 1.0, parameter_pitch = 1.0, parameter_unit_size = 1.0;
    for (const Ref<SfxParameterModulation> &modulation : instance->event->parameter_modulations.items) {
        if (modulation.is_null() || modulation->parameter_name.is_empty()) {
            continue;
        }
        double result = param(instance, modulation->parameter_name, modulation->default_value);
        if (modulation->curve.is_valid()) {
            result = modulation->curve->sample(CLAMP(result, modulation->min_domain, modulation->max_domain));
        }
        switch (modulation->target) {
            case SfxParameterModulation::GAIN:
                parameter_gain *= MAX(result, 0.0);
                break;
            case SfxParameterModulation::PITCH:
                parameter_pitch *= MAX(result, 0.01);
                break;
            case SfxParameterModulation::UNIT_SIZE:
                parameter_unit_size *= MAX(result, 0.01);
                break;
        }
    }

    const SfxEvent &event = **instance->event;
    Ref<SfxTrack> track = mixer_track(p_voice);
    double event_adsr = instance->adsr.gain(event.adsr_enabled, event.attack, event.decay, event.sustain, event.release);
    double track_adsr = track.is_null() ? 1.0 : p_voice->track_adsr.gain(track->adsr_enabled, track->attack, track->decay, track->sustain, track->release);
    double gain = CLAMP(event_adsr, 0.0, 1.0) * CLAMP(track_adsr, 0.0, 1.0) * clip_gain * mixer_gain(p_voice) * parameter_gain;
    slot.apply_gain(Math::linear_to_db(MAX(gain, 0.0001)));
    slot.apply_pitch(MAX(pitch * parameter_pitch * event.pitch_variation, 0.01), clock);
    if (event.spatial_config.is_valid()) {
        slot.apply_spatial(event.spatial_config, event.spatial_config->unit_size * parameter_unit_size);
    } else {
        slot.clear_spatial();
    }
}

bool SfxPlaybackRuntime::automation_voice_releasing(const Voice *p_voice) const {
    return p_voice->stopping || p_voice->finish_on_end || p_voice->track_adsr.stage == ADSR_RELEASE || p_voice->track_adsr.stage == ADSR_STOPPED;
}

bool SfxPlaybackRuntime::begin_voice_stop(Voice *p_voice) {
    if (p_voice->automation.is_valid()) {
        return begin_automation_voice_stop(p_voice);
    }
    if (begin_track_release(p_voice)) {
        apply_voice_state(p_voice);
        return true;
    }
    double fade = curve_duration(p_voice->clip->fade_out_curve);
    if (fade <= 0.0) {
        return false;
    }
    p_voice->stopping = true;
    p_voice->stop_elapsed = 0.0;
    p_voice->stop_fade = fade;
    apply_voice_state(p_voice);
    return true;
}

bool SfxPlaybackRuntime::begin_automation_voice_stop(Voice *p_voice) {
    p_voice->automation_release_gain = p_voice->automation_current_gain;
    if (begin_track_release(p_voice)) {
        apply_voice_state(p_voice);
        return true;
    }
    return false;
}

void SfxPlaybackRuntime::stop_automation_voice(Voice *p_voice) {
    if (!begin_automation_voice_stop(p_voice)) {
        stop_voice(find_voice_index(p_voice));
    }
}

// The automation left the clip but the clip has no cut: it plays to the end of the lap it is in,
// on its stream without a loop (SfxClip::drain_stream), restarted where it was
void SfxPlaybackRuntime::finish_automation_voice_on_end(Voice *p_voice) {
    Slot &slot = slots[p_voice->slot];
    double position = slot.position(clock);
    bool was_looping = slot.looping;
    if (was_looping && p_voice->stream == p_voice->clip->stream && p_voice->clip->drain_stream.is_valid()) {
        p_voice->stream = p_voice->clip->drain_stream;
        slot.swap_stream(p_voice->stream);
    }
    p_voice->automation_release_gain = p_voice->automation_current_gain;
    p_voice->finish_on_end = true;
    p_voice->stream_end = stream_length(p_voice->stream);
    if (p_voice->stream_end > 0.0) {
        slot.replay(tail_start_position(position, p_voice->stream_end, was_looping), clock);
    }
    // without a drained copy the node still loops: its clock does not, so the runtime stops it at the end
    slot.looping = false;
    slot.loop_end = p_voice->stream_end;
    apply_voice_state(p_voice);
}

void SfxPlaybackRuntime::restart_automation_voice(Voice *p_voice) {
    Slot &slot = slots[p_voice->slot];
    if (p_voice->finish_on_end) {
        p_voice->stream = p_voice->clip->stream;
        slot.swap_stream(p_voice->stream);
    }
    double end = voice_end_position(**p_voice->clip, p_voice->stream);
    double start = voice_start_position(p_voice->instance, p_voice->clip, p_voice->automation, p_voice->stream);
    p_voice->stream_start = end > 0.0 ? MIN(start, end) : start;
    p_voice->stream_end = end;
    p_voice->stopping = p_voice->finish_on_end = false;
    p_voice->stop_elapsed = p_voice->stop_fade = 0.0;
    p_voice->automation_current_gain = p_voice->automation_release_gain = 1.0;
    slot.replay(p_voice->stream_start, clock);
    Ref<SfxTrack> track = mixer_track(p_voice);
    p_voice->track_adsr.enter(track.is_valid() && track->adsr_enabled, track.is_valid() ? track->attack : 0.0, track.is_valid() ? track->decay : 0.0);
    apply_voice_state(p_voice);
}

// The AudioStreamGeneratorPlayback exists once the main thread has started the node, so a generator
// voice picks it up from its slot on the first tick after that and builds its state then
void SfxPlaybackRuntime::pump_generator(Voice *p_voice, double p_delta) {
    if (p_voice->generator.is_null()) {
        return;
    }
    Slot &slot = slots[p_voice->slot];
    if (p_voice->generator_stream_playback.is_null()) {
        p_voice->generator_stream_playback = slot.generator_stream_playback;
        if (p_voice->generator_stream_playback.is_null()) {
            return;
        }
        p_voice->generator->_gdvirtual__create_state_call(p_voice->generator_stream_playback, p_voice->clip, p_voice->generator_state);
    }
    Instance *instance = p_voice->instance;
    if (instance->params_dictionary_stale) {
        instance->params_dictionary = Dictionary();
        for (const KeyValue<StringName, double> &entry : instance->params) {
            instance->params_dictionary[entry.key] = entry.value;
        }
        instance->params_dictionary_stale = false;
    }
    Dictionary &context = p_voice->generator_context;
    context["delta"] = p_delta;
    context["playback_position"] = slot.position(clock);
    context["event_name"] = instance->name;
    context["clip"] = p_voice->clip;
    context["stream_playback"] = p_voice->generator_stream_playback;
    context["event_time"] = instance->playback_time;
    context["parameters"] = instance->params_dictionary;
    context["automation_name"] = p_voice->automation_name;
    context["automation_value"] = p_voice->automation.is_valid() ? Variant(param(instance, p_voice->automation_name, p_voice->automation->min_domain)) : Variant();
    p_voice->generator->_gdvirtual__update_call(p_voice->generator_state, context);
}

void SfxPlaybackRuntime::release_voice(int p_index) {
    if (p_index < 0) {
        return;
    }
    Voice *voice = voices[p_index].get();
    if (voice->generator.is_valid() && voice->generator_stream_playback.is_valid()) {
        voice->generator->_gdvirtual__cleanup_call(voice->generator_state);
    }
    Slot &slot = slots[voice->slot];
    if (slot.token == voice->slot_token) {
        slot.clear_spatial();
        slot.apply_gain(0.0);
        slot.apply_pitch(1.0, clock);
    }
    voices.erase(voices.begin() + p_index);
    finished_pending = finished_pending || (voices.empty() && instances.empty());
}

void SfxPlaybackRuntime::stop_voice(int p_index) {
    if (p_index < 0) {
        return;
    }
    int slot = voices[p_index]->slot;
    bool owns_slot = slots[slot].token == voices[p_index]->slot_token;
    release_voice(p_index);
    if (owns_slot) {
        slots[slot].reset(true, clock);
    }
}

void SfxPlaybackRuntime::update_voice(int p_index, double p_delta) {
    Voice *voice = voices[p_index].get();
    Slot &slot = slots[voice->slot];
    if (!voice->finish_on_end && !slot.playing) {
        release_voice(p_index);
        return;
    }
    if (voice->stopping) {
        voice->stop_elapsed += p_delta;
        if (voice->stop_fade <= 0.0 || voice->stop_elapsed >= voice->stop_fade) {
            stop_voice(p_index);
            return;
        }
    }
    if (voice->finish_on_end && (voice->stream_end <= 0.0 || slot.position(clock) >= voice->stream_end)) {
        stop_voice(p_index);
        return;
    }
    Ref<SfxTrack> track = mixer_track(voice);
    bool adsr = track.is_valid() && track->adsr_enabled;
    voice->track_adsr.advance(p_delta, adsr, adsr ? track->attack : 0.0, adsr ? track->decay : 0.0, adsr ? track->release : 0.0);
    if (voice->track_adsr.stage == ADSR_STOPPED) {
        stop_voice(p_index);
        return;
    }
    // a clip cut short by its length is stopped here; a stream that ends on its own says so itself
    if (voice->automation.is_null() && voice->truncated && slot.position(clock) >= voice->stream_end) {
        stop_voice(p_index);
        return;
    }
    apply_voice_state(voice);
    pump_generator(voice, p_delta);
}

// --- The tick ----------------------------------------------------------------------------------

void SfxPlaybackRuntime::update(double p_delta) {
    clock += p_delta;
    if (parameters_changed || !derived.is_empty()) {
        update_parameters(p_delta);
    }
    for (size_t i = 0; i < instances.size();) {
        Instance *instance = instances[i].get();
        update_instance(instance, p_delta);
        i += i < instances.size() && instances[i].get() == instance;
    }
    for (int i = int(voices.size()) - 1; i >= 0; i--) {
        if (i < int(voices.size())) {
            update_voice(i, p_delta);
        }
    }
    collect_finished_instances();
}

double SfxPlaybackRuntime::get_next_wake() const {
    if (parameters_changed) {
        return clock;
    }
    for (const Derived &entry : derived) {
        if (!entry.settled) {
            return clock;
        }
    }
    double wake = NEVER;
    for (const std::unique_ptr<Instance> &instance : instances) {
        if (instance->automation_refresh_pending || instance->adsr.moving()) {
            return clock;
        }
        for (const Ref<SfxClip> &clip : instance->event->clips.items) {
            if (instance->status == STATUS_PLAYING && clip.is_valid() && clip->trigger_mode == SfxClip::TRIGGER_TIMELINE &&
                    !has(instance->triggered_event_clips, clip)) {
                wake = MIN(wake, clock + MAX(clip->offset - instance->playback_time, 0.0));
            }
        }
    }
    for (const std::unique_ptr<Voice> &voice : voices) {
        const Slot &slot = slots[voice->slot];
        if (voice->generator.is_valid() || voice->stopping || voice->track_adsr.moving()) {
            return clock;
        }
        double position = slot.position(clock);
        double pitch = MAX(slot.pitch_scale, 0.01);
        if (voice->finish_on_end || (voice->automation.is_null() && voice->truncated)) {
            wake = MIN(wake, clock + MAX(voice->stream_end - position, 0.0) / pitch);
        }
        if (voice->automation.is_valid() || voice->finish_on_end) {
            continue;
        }
        const SfxClip &clip = **voice->clip;
        double local = position - voice->stream_start;
        if (local < curve_duration(clip.fade_in_curve) || local < curve_duration(clip.pitch_curve)) {
            return clock;
        }
        double fade_out = curve_duration(clip.fade_out_curve);
        double end = voice->stream_end > 0.0 ? voice->stream_end : stream_length(voice->stream);
        if (fade_out > 0.0 && !slot.looping && end > 0.0) {
            wake = MIN(wake, clock + MAX(end - fade_out - position, 0.0) / pitch);
        }
    }
    return wake;
}

bool SfxPlaybackRuntime::requires_process() const {
    return !voices.empty() || !instances.empty() || get_next_wake() < NEVER;
}

// --- The API -----------------------------------------------------------------------------------

void SfxPlaybackRuntime::set_slot_capacity(int p_capacity) {
    slot_capacity = MAX(p_capacity, 0);
    if (int(slots.size()) > slot_capacity) {
        slots.resize(slot_capacity);
    }
}

void SfxPlaybackRuntime::seek(const StringName &p_event_name, double p_offset) {
    Instance *instance = latest_instance(p_event_name);
    if (!instance) {
        return;
    }
    Ref<SfxEvent> event = instance->event;
    HashMap<StringName, double> params = std::move(instance->params);
    Adsr adsr = instance->adsr;
    double release_time = instance->release_time;
    bool releasing = instance->status == STATUS_RELEASING;
    LocalVector<Ref<SfxClip>> sustain = std::move(instance->triggered_sustain_clips);
    stop_event_instance(instance, true);

    instances.push_back(std::make_unique<Instance>());
    Instance *rebuilt = instances.back().get();
    rebuilt->id = ++instance_counter;
    rebuilt->event = event;
    rebuilt->name = p_event_name;
    rebuilt->playback_time = MAX(p_offset, 0.0);
    rebuilt->release_time = release_time;
    rebuilt->params = std::move(params);
    rebuilt->status = releasing ? STATUS_RELEASING : STATUS_PLAYING;
    rebuilt->adsr = adsr;
    rebuilt->triggered_sustain_clips = std::move(sustain);
    refresh_event_clips(rebuilt, -1.0, rebuilt->playback_time, false);
    if (releasing) {
        refresh_event_clips(rebuilt, -1.0, rebuilt->release_time, true);
    }
    refresh_automation_clips(rebuilt);
}

// Only the values are written here; which clips that leaves playing is worked out by the next tick
void SfxPlaybackRuntime::modulate(const StringName &p_event_name, const Dictionary &p_parameters) {
    Instance *instance = latest_instance(p_event_name);
    if (!instance) {
        return;
    }
    Array keys = p_parameters.keys();
    for (int64_t i = 0; i < keys.size(); i++) {
        double value = p_parameters[keys[i]];
        double *current = instance->params.getptr(keys[i]);
        if (!current || *current != value) {
            instance->params[keys[i]] = value;
            instance->automation_refresh_pending = true;
            instance->params_dictionary_stale = true;
        }
    }
}

void SfxPlaybackRuntime::set_parameters(const Dictionary &p_parameters) {
    Array keys = p_parameters.keys();
    for (int64_t i = 0; i < keys.size(); i++) {
        if (p_parameters[keys[i]].get_type() == Variant::DICTIONARY) {
            modulate(keys[i], p_parameters[keys[i]]);
        }
    }
}

// stop() / stop(true) stops everything, stop("event") / stop("event", true) just that event
void SfxPlaybackRuntime::stop(const Variant &p_event_name_or_immediate, bool p_immediate) {
    if (p_event_name_or_immediate.get_type() == Variant::BOOL) {
        stop_all(p_event_name_or_immediate);
    } else if (p_event_name_or_immediate.booleanize()) {
        stop_event(p_event_name_or_immediate, p_immediate);
    } else {
        stop_all(p_immediate);
    }
}

void SfxPlaybackRuntime::stop_all(bool p_immediate) {
    LocalVector<Instance *> all;
    for (const std::unique_ptr<Instance> &instance : instances) {
        all.push_back(instance.get());
    }
    for (Instance *instance : all) {
        stop_event_instance(instance, p_immediate);
    }
    collect_finished_instances();
}

// Stops the newest playing instance of a polyphonic event - the latest play(), not all of them
void SfxPlaybackRuntime::stop_event(const StringName &p_event_name, bool p_immediate) {
    if (Instance *instance = latest_instance(p_event_name, true)) {
        stop_event_instance(instance, p_immediate);
    }
    collect_finished_instances();
}

void SfxPlaybackRuntime::play_automation(const Ref<SfxEvent> &p_event, const StringName &p_automation, double p_value, bool p_restart) {
    if (p_event.is_null()) {
        return;
    }
    Dictionary parameters;
    parameters[p_automation] = p_value;
    if (p_restart || !is_playing(p_event->name)) {
        play(p_event, 0.0, parameters);
    } else {
        modulate(p_event->name, parameters);
    }
}

void SfxPlaybackRuntime::stop_automation(const Ref<SfxEvent> &p_event, const StringName &p_automation, bool p_immediate) {
    if (p_event.is_valid()) {
        stop_event(p_event->name, p_immediate);
    }
}

bool SfxPlaybackRuntime::is_playing(const StringName &p_event_name) const {
    return latest_instance(p_event_name) != nullptr;
}

void SfxPlaybackRuntime::clear() {
    bool had_activity = !voices.empty() || !instances.empty();
    for (const std::unique_ptr<Voice> &voice : voices) {
        if (voice->generator.is_valid() && voice->generator_stream_playback.is_valid()) {
            voice->generator->_gdvirtual__cleanup_call(voice->generator_state);
        }
    }
    voices.clear();
    instances.clear();
    for (Slot &slot : slots) {
        slot.reset(true, clock);
    }
    // a gate whose event was cut opens again, past the event's opening (resume_offset)
    for (Trigger &trigger : triggers) {
        trigger.resume = trigger.open;
        if (trigger.open) {
            mark_parameter(trigger.index);
        }
        trigger.open = false;
    }
    finished_pending = finished_pending || had_activity;
}

bool SfxPlaybackRuntime::consume_finished() {
    bool finished = finished_pending;
    finished_pending = false;
    return finished;
}

void SfxPlaybackRuntime::handle_slot_finished(int p_slot) {
    ERR_FAIL_INDEX(p_slot, int(slots.size()));
    slots[p_slot].playing = false;
    release_voice(find_slot_voice(p_slot, slots[p_slot].token));
}

// --- Visualisation and debugging ---------------------------------------------------------------

static double visual_span(const SfxClip *p_clip, const Ref<AudioStream> &p_stream, bool p_use_clip_length) {
    if (!p_clip) {
        return 0.35;
    }
    if (p_use_clip_length && p_clip->length > 0.0) {
        return p_clip->length;
    }
    for (const Ref<AudioStream> &stream : { p_stream, p_clip->stream }) {
        if (stream_length(stream) > 0.0) {
            return MAX(stream_length(stream) - MAX(p_clip->stream_offset, 0.0), 0.0);
        }
    }
    return 0.35;
}

static double wrap_or_clamp(double p_position, double p_span, bool p_looping) {
    return p_span <= 0.0 ? p_position : p_looping ? Math::fposmod(p_position, p_span) : CLAMP(p_position, 0.0, p_span);
}

Dictionary SfxPlaybackRuntime::visual_clip_state(const Ref<SfxClip> &p_clip, const Voice *p_voice, bool p_use_clip_length, const Instance *p_instance) const {
    Dictionary state;
    state["active"] = p_voice != nullptr;
    state["visible_span"] = visual_span(p_clip.ptr(), p_voice ? p_voice->stream : Ref<AudioStream>(), p_use_clip_length);
    state["position"] = 0.0;
    state["loops"] = false;
    if (!p_voice) {
        return state;
    }
    double span = state["visible_span"];
    bool looping = SfxStreamLoopSupport::is_looping(p_voice->stream);
    double position = p_instance && p_clip->trigger_mode == SfxClip::TRIGGER_TIMELINE
            ? MAX(p_instance->playback_time - MAX(p_clip->offset, 0.0), 0.0)
            : MAX(slots[p_voice->slot].position(clock) - MAX(p_clip->stream_offset, 0.0), 0.0);
    state["position"] = wrap_or_clamp(position, span, looping);
    state["loops"] = looping;
    return state;
}

// A snapshot of the latest instance for the editor's timelines - not used by playback
Dictionary SfxPlaybackRuntime::get_event_visualization_state(const StringName &p_event_name) const {
    Dictionary state;
    state["event_name"] = p_event_name;
    Instance *instance = latest_instance(p_event_name);
    Dictionary parameters, clips, automation_clips;
    if (instance) {
        for (const KeyValue<StringName, double> &entry : instance->params) {
            parameters[entry.key] = entry.value;
        }
        for (const Ref<SfxClip> &clip : instance->event->clips.items) {
            if (clip.is_valid()) {
                clips[clip] = visual_clip_state(clip, find_voice(instance, clip), true, instance);
            }
        }
        for (const Ref<SfxAutomation> &automation : instance->event->automations.items) {
            if (automation.is_null() || automation->parameter_name.is_empty()) {
                continue;
            }
            Dictionary automation_states;
            for (const Ref<SfxClip> &clip : automation->clips.items) {
                if (clip.is_valid()) {
                    automation_states[clip] = visual_clip_state(clip, find_voice(instance, clip, automation->parameter_name), false, nullptr);
                }
            }
            automation_clips[automation->parameter_name] = automation_states;
        }
    }
    state["playing"] = instance && instance->status != STATUS_STOPPED;
    state["event_time"] = instance ? instance->playback_time : 0.0;
    state["parameters"] = parameters;
    state["clips"] = clips;
    state["automation_clips"] = automation_clips;
    return state;
}

Array SfxPlaybackRuntime::get_debug_voices() const {
    Array result;
    for (const std::unique_ptr<Voice> &voice : voices) {
        Dictionary entry;
        entry["slot"] = voice->slot;
        entry["instance_id"] = int64_t(voice->instance->id);
        entry["event_name"] = voice->instance->name;
        entry["clip"] = voice->clip;
        entry["stream"] = voice->stream;
        entry["automation_name"] = voice->automation_name;
        entry["stream_start_position"] = voice->stream_start;
        entry["stream_end_position"] = voice->stream_end;
        entry["track_adsr_stage"] = voice->track_adsr.stage;
        entry["stopping"] = voice->stopping;
        entry["finish_on_end"] = voice->finish_on_end;
        entry["creation_order"] = int64_t(voice->creation_order);
        result.push_back(entry);
    }
    return result;
}

Array SfxPlaybackRuntime::get_debug_slots() const {
    Array result;
    for (const Slot &slot : slots) {
        Dictionary entry;
        entry["stream"] = slot.stream;
        entry["start_position"] = slot.start_position;
        entry["transport"] = slot.transport;
        entry["play_serial"] = slot.play_serial;
        entry["volume_db"] = slot.volume_db;
        entry["pitch_scale"] = slot.pitch_scale;
        entry["playing"] = slot.playing;
        entry["position"] = slot.position(clock);
        entry["looping"] = slot.looping;
        entry["spatial_override"] = slot.spatial_override;
        entry["dirty"] = slot.dirty;
        result.push_back(entry);
    }
    return result;
}

PackedInt64Array SfxPlaybackRuntime::get_instance_ids(const StringName &p_event_name) const {
    PackedInt64Array ids;
    for (const std::unique_ptr<Instance> &instance : instances) {
        if (instance->name == p_event_name) {
            ids.push_back(instance->id);
        }
    }
    return ids;
}

void SfxPlaybackRuntime::_bind_methods() {
    BIND_ENUM_CONSTANT(ADSR_IDLE);
    BIND_ENUM_CONSTANT(ADSR_ATTACK);
    BIND_ENUM_CONSTANT(ADSR_DECAY);
    BIND_ENUM_CONSTANT(ADSR_SUSTAIN);
    BIND_ENUM_CONSTANT(ADSR_RELEASE);
    BIND_ENUM_CONSTANT(ADSR_STOPPED);
    ClassDB::bind_method(D_METHOD("set_slot_capacity", "capacity"), &SfxPlaybackRuntime::set_slot_capacity);
    ClassDB::bind_method(D_METHOD("set_bank", "bank"), &SfxPlaybackRuntime::set_bank);
    ClassDB::bind_method(D_METHOD("set_parameter", "name", "value"), &SfxPlaybackRuntime::set_parameter);
    ClassDB::bind_method(D_METHOD("get_parameter", "name"), &SfxPlaybackRuntime::get_parameter);
    ClassDB::bind_method(D_METHOD("set_parameter_values", "values"), &SfxPlaybackRuntime::set_parameter_values);
    ClassDB::bind_method(D_METHOD("play", "event", "offset", "parameters"), &SfxPlaybackRuntime::play_event, DEFVAL(0.0), DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("seek", "event_name", "offset"), &SfxPlaybackRuntime::seek);
    ClassDB::bind_method(D_METHOD("modulate", "event_name", "parameters"), &SfxPlaybackRuntime::modulate);
    ClassDB::bind_method(D_METHOD("set_parameters", "parameters"), &SfxPlaybackRuntime::set_parameters);
    ClassDB::bind_method(D_METHOD("stop", "event_name_or_immediate", "immediate"), &SfxPlaybackRuntime::stop, DEFVAL(Variant()), DEFVAL(false));
    ClassDB::bind_method(D_METHOD("stop_all", "immediate"), &SfxPlaybackRuntime::stop_all, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("stop_event", "event_name", "immediate"), &SfxPlaybackRuntime::stop_event, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("play_automation", "event", "automation_name", "value", "restart"), &SfxPlaybackRuntime::play_automation, DEFVAL(0.0), DEFVAL(false));
    ClassDB::bind_method(D_METHOD("stop_automation", "event", "automation_name", "immediate"), &SfxPlaybackRuntime::stop_automation, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("is_playing", "event_name"), &SfxPlaybackRuntime::is_playing);
    ClassDB::bind_method(D_METHOD("get_event_visualization_state", "event_name"), &SfxPlaybackRuntime::get_event_visualization_state);
    ClassDB::bind_method(D_METHOD("update", "delta"), &SfxPlaybackRuntime::update);
    ClassDB::bind_method(D_METHOD("clear"), &SfxPlaybackRuntime::clear);
    ClassDB::bind_method(D_METHOD("requires_process"), &SfxPlaybackRuntime::requires_process);
    ClassDB::bind_method(D_METHOD("get_next_wake"), &SfxPlaybackRuntime::get_next_wake);
    ClassDB::bind_method(D_METHOD("get_clock"), &SfxPlaybackRuntime::get_clock);
    ClassDB::bind_method(D_METHOD("handle_slot_finished", "slot"), &SfxPlaybackRuntime::handle_slot_finished);
    ClassDB::bind_method(D_METHOD("get_debug_voices"), &SfxPlaybackRuntime::get_debug_voices);
    ClassDB::bind_method(D_METHOD("get_debug_slots"), &SfxPlaybackRuntime::get_debug_slots);
    ClassDB::bind_method(D_METHOD("get_instance_ids", "event_name"), &SfxPlaybackRuntime::get_instance_ids);
    ClassDB::bind_static_method("SfxPlaybackRuntime", D_METHOD("sample_time_curve", "curve", "elapsed", "from_end"), &SfxPlaybackRuntime::sample_time_curve);
    ClassDB::bind_static_method("SfxPlaybackRuntime", D_METHOD("sample_automation_curve", "curve", "value", "offset"), &SfxPlaybackRuntime::sample_automation_curve);
    ClassDB::bind_static_method("SfxPlaybackRuntime", D_METHOD("sample_automation_fade_out", "curve", "clip", "value"), &SfxPlaybackRuntime::sample_automation_fade_out);
    ClassDB::bind_static_method("SfxPlaybackRuntime", D_METHOD("tail_start_position", "position", "end", "was_looping"), &SfxPlaybackRuntime::tail_start_position);
}
