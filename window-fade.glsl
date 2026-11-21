#version 320 es
// @duration 2.0
// @unfocus_delay 1.0
precision highp float;

uniform sampler2D tex;
uniform float progress;
in vec2 v_texcoord;
out vec4 fragColor;

const float restingSaturation = 0.60;
const float restingBrightness = 0.75;

void main() {
    vec4 color = texture(tex, v_texcoord);
    float fade = smoothstep(0.0, 1.0, progress);
    float saturation = mix(1.0, restingSaturation, fade);
    float brightness = mix(1.0, restingBrightness, fade);
    float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
    fragColor = vec4(mix(vec3(luminance), color.rgb, saturation) * brightness, color.a);
}
