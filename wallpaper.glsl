#version 320 es
precision highp float;

uniform sampler2D tex;
uniform vec2 window_fade_wallpaper_adjustments;
in vec2 v_texcoord;
out vec4 fragColor;

void main() {
    vec4 color = texture(tex, v_texcoord);
    float brightness = window_fade_wallpaper_adjustments.x;
    float saturation = window_fade_wallpaper_adjustments.y;
    float gray = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
    fragColor = vec4(mix(vec3(gray), color.rgb, saturation) * brightness, color.a);
}
