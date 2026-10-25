#include "gnd_sfx_server.hpp"
#include "sfx_player.hpp"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    GDREGISTER_CLASS(SfxGeneratorPlayback);
    GDREGISTER_CLASS(SfxTrack);
    GDREGISTER_CLASS(SfxClip);
    GDREGISTER_CLASS(SfxAutomation);
    GDREGISTER_CLASS(SfxParameterModulation);
    GDREGISTER_CLASS(SfxSpatialConfig);
    GDREGISTER_CLASS(SfxParameterTrigger);
    GDREGISTER_CLASS(SfxEvent);
    GDREGISTER_CLASS(SfxParameter);
    GDREGISTER_CLASS(SfxDerivedParameter);
    GDREGISTER_CLASS(SfxBank);
    GDREGISTER_ABSTRACT_CLASS(SfxStreamLoopSupport);
    GDREGISTER_CLASS(SfxPlaybackRuntime);
    GDREGISTER_CLASS(SfxPlayer);
    GDREGISTER_CLASS(SfxPlayer3D);
    GDREGISTER_CLASS(GndSfxServer);
    GDREGISTER_INTERNAL_CLASS(GndSfxServerPoster);
    GndSfxServer::register_settings();
}

static void uninitialize(ModuleInitializationLevel p_level) {
}

extern "C" GDExtensionBool GDE_EXPORT gndsfx_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
        GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
    GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
    init_obj.register_initializer(initialize);
    init_obj.register_terminator(uninitialize);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
