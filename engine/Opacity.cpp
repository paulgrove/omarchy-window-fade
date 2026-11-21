#include "Globals.hpp"

#include <algorithm>
#include <cmath>
#include <lua.hpp>

namespace WindowFadeOpacity {
    using Desktop::View::CWindow;
    using Desktop::View::CWindowPresentation;

    struct Owner {
        CWindow* key;
        PHLWINDOWREF window;
    };

    struct Profile {
        float opacity;
        float seconds;
        bool operator==(const Profile&) const = default;
    };

    static std::unordered_map<const CWindowPresentation*, Owner> windows;
    static std::unordered_map<std::string, Profile> profiles;
    static CFunctionHook* presentationHook = nullptr;
    static CFunctionHook* opaqueHook = nullptr;

    void track(const PHLWINDOW& window, bool shaded) {
        const auto* presentation = &window->presentation();
        if (shaded)
            windows.insert_or_assign(presentation, Owner{window.get(), window});
        else
            windows.erase(presentation);
    }

    void forget(CWindow* window) {
        std::erase_if(windows, [window](const auto& entry) { return entry.second.key == window; });
    }

    static float opacityFactor(const CWindowPresentation* presentation) {
        const auto owner = windows.find(presentation);
        if (owner == windows.end()) return 1.F;
        const auto rules = g_mWindowRuleShaders.find(owner->second.key);
        if (rules == g_mWindowRuleShaders.end()) return 1.F;
        const auto profile = profiles.find(rules->second.inactive);
        if (profile == profiles.end() || profile->second.opacity >= 1.F) return 1.F;

        const auto window = owner->second.window.lock();
        if (!window || Desktop::focusState()->isWindowActive(window) || Fullscreen::controller()->isFullscreen(window))
            return 1.F;

        const auto shot = g_mWindowOneShots.find(owner->second.key);
        if (shot == g_mWindowOneShots.end() || shot->second.kind != ONESHOT_UNFOCUS)
            return profile->second.opacity;

        const float elapsed = std::chrono::duration<float>(std::chrono::steady_clock::now() - shot->second.start).count();
        if (elapsed < 0.F) return 1.F;
        if (profile->second.seconds <= 0.F) return profile->second.opacity;
        const float progress = std::clamp(elapsed / profile->second.seconds, 0.F, 1.F);
        const float eased = progress * progress * (3.F - 2.F * progress);
        return std::lerp(1.F, profile->second.opacity, eased);
    }

    // Apply native window alpha before render-pass construction and occlusion.
    // Writing alpha into the fragment shader cannot reveal pixels Hyprland has
    // already decided are fully covered.
    static Render::SWindowPresentationState presentationState(const CWindowPresentation* self,
        const SP<Workspace::CWorkspacePresentable>& workspace) {
        using Original = Render::SWindowPresentationState (*)(const CWindowPresentation*, const SP<Workspace::CWorkspacePresentable>&);
        auto state = reinterpret_cast<Original>(presentationHook->m_original)(self, workspace);
        state.active *= opacityFactor(self);
        return state;
    }

    static bool opaque(const CWindowPresentation* self, const Render::SWindowRenderPresentation& presentation) {
        using Original = bool (*)(const CWindowPresentation*, const Render::SWindowRenderPresentation&);
        return opacityFactor(self) >= 1.F && reinterpret_cast<Original>(opaqueHook->m_original)(self, presentation);
    }

    static int setProfile(lua_State* state) {
        const std::string path = luaL_checkstring(state, 1);
        const auto opacity = luaL_checknumber(state, 2);
        const auto seconds = luaL_checknumber(state, 3);
        if (!std::isfinite(opacity) || !std::isfinite(seconds))
            return luaL_error(state, "expected finite Window Fade opacity and duration");

        const Profile next{static_cast<float>(std::clamp(opacity, 0.0, 1.0)),
                           static_cast<float>(std::clamp(seconds, 0.0, 5.0))};
        const auto previous = profiles.find(path);
        if (previous != profiles.end() && previous->second == next) return 0;
        profiles.insert_or_assign(path, next);
        for (const auto& [_, owner] : windows) {
            const auto rules = g_mWindowRuleShaders.find(owner.key);
            if (rules != g_mWindowRuleShaders.end() && rules->second.inactive == path) {
                if (const auto window = owner.window.lock())
                    g_pHyprRenderer->damageWindow(window);
            }
        }
        return 0;
    }

    static bool hook(HANDLE handle, const std::string& name, const std::string& signature, void* handler, CFunctionHook*& slot) {
        for (const auto& method : HyprlandAPI::findFunctionsByName(handle, name)) {
            if (!method.address || method.signature.find(signature) == std::string::npos) continue;
            slot = HyprlandAPI::createFunctionHook(handle, method.address, handler);
            return slot && slot->hook();
        }
        return false;
    }

    bool install(HANDLE handle) {
        if (hook(handle, "renderPresentationState", "19CWindowPresentation23renderPresentationState",
                 reinterpret_cast<void*>(&presentationState), presentationHook)
            && hook(handle, "opaque", "19CWindowPresentation6opaqueERKN6Render25SWindowRenderPresentationE",
                    reinterpret_cast<void*>(&opaque), opaqueHook)
            && HyprlandAPI::addLuaFunction(handle, "HyprWindowShade", "setwindowfadeopacity", &setProfile))
            return true;
        uninstall(handle);
        return false;
    }

    void uninstall(HANDLE handle) {
        HyprlandAPI::removeLuaFunction(handle, "HyprWindowShade", "setwindowfadeopacity");
        if (opaqueHook) HyprlandAPI::removeFunctionHook(handle, opaqueHook);
        if (presentationHook) HyprlandAPI::removeFunctionHook(handle, presentationHook);
        opaqueHook = nullptr;
        presentationHook = nullptr;
        profiles.clear();
        windows.clear();
    }
}
