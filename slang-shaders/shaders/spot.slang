#version 450

layout(set = 0, binding = 0, std140) uniform UBO {
    mat4 MVP;
};

layout(push_constant) uniform Push {
    vec4 SourceSize;
    vec4 OutputSize;
    uint FrameCount;
    float MaxSpotSize;
    float MinSpotSize;
    float OddFieldFirst;
    float OverscanHorizontal;
    float OverscanVertical;
} params;

#pragma parameter MaxSpotSize "Maximum spot size (proportion of scanline)" 0.95 0.6 1.0 0.05
#pragma parameter MinSpotSize "Minimum spot size (proportion of maximum)" 0.5 0.3 1.0 0.1
#pragma parameter OddFieldFirst "Interlacing (phase)" 0.0 0.0 1.0 1.0
#pragma parameter OverscanHorizontal "Horizontal overscan (proportion to crop)" 0.0 0.0 0.1 0.01
#pragma parameter OverscanVertical "Vertical overscan (proportion to crop)" 0.0 0.0 0.1 0.01

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main() {
    gl_Position = MVP * Position;
    vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(binding = 1) uniform sampler2D Source;
layout(binding = 2) uniform sampler2D Filtered;

vec3 spot(vec3 sample_value, vec3 width_rcp, float distance_x, float distance_y) {
    vec3 x = clamp(abs(distance_x) * width_rcp, 0.0, 1.0);
    vec3 y = clamp(abs(distance_y) * width_rcp, 0.0, 1.0);
    vec3 w = max(vec3(1.0), width_rcp * width_rcp); // correct gamma for scanline width, allowing bloom on overlap
    return sample_value * w * ((x * x) * (2.0 * x - 3.0) + 1.0) * ((y * y) * (2.0 * y - 3.0) + 1.0);
}

void main() {
    // Handle overscan.
    vec2 pos = (1.0 - vec2(params.OverscanHorizontal, params.OverscanVertical)) * (vTexCoord - 0.5) + 0.5;

    // Sample locations in Source texel space: [0, SourceSize.y), snapped to the
    // middle of a texel.
    float upper_sample_y, lower_sample_y;
    // Distance units are *scanlines heights*. delta is the distance between
    // samples on the x-axis, and has to be adjusted by the aspect ratio.
    // Overescan changes the aspect ratio and needs to be taken into account.
    float delta, upper_distance_y;
    // Check if we should be interlacing. If we are, grab two closest even or
    // odd lines. If we aren't, just grab the two closest lines.
    if (params.SourceSize.y > 300.0) {  // Interlacing
        if ((params.FrameCount + (params.OddFieldFirst > 0.5 ? 1u : 0u)) % 2u == 0u) {
            upper_sample_y = floor(ceil(pos.y * params.SourceSize.y + 0.5) * 0.5) * 2.0 + 0.5;
        } else {
            upper_sample_y = floor(floor(pos.y * params.SourceSize.y + 0.5) * 0.5) * 2.0 + 1.5;
        }
        lower_sample_y = upper_sample_y - 2.0;
        // TODO 0.5 doesn't quite work with an odd number of lines. Does that ever happen?
        delta = 0.5 * params.OutputSize.x * params.OutputSize.w *
                params.SourceSize.y * params.SourceSize.z *
                (1 - params.OverscanVertical) / (1 - params.OverscanHorizontal);
        upper_distance_y = 0.5 * (upper_sample_y - pos.y * params.SourceSize.y);
    } else {  // No interlacing
        upper_sample_y = round(pos.y * params.SourceSize.y) + 0.5;
        lower_sample_y = upper_sample_y - 1.0;
        delta = params.OutputSize.x * params.OutputSize.w *
                params.SourceSize.y * params.SourceSize.z *
                (1 - params.OverscanVertical) / (1 - params.OverscanHorizontal);
        upper_distance_y = upper_sample_y - pos.y * params.SourceSize.y;
    }
    float lower_distance_y = upper_distance_y - 1.0;

    // Transform *_sample_y into [0,1] coordinate space. We need them for the
    // texture sampling below.
    upper_sample_y *= params.SourceSize.w;
    lower_sample_y *= params.SourceSize.w;

    vec3 value = vec3(0.0);
    float start_x = params.SourceSize.z * (round(pos.x * params.SourceSize.x - (params.MaxSpotSize / delta)) + 0.5);
    float stop_x = params.SourceSize.z * round(pos.x * params.SourceSize.x + (params.MaxSpotSize / delta));
    float distance_x = delta * params.SourceSize.x * (start_x - pos.x);
    for (float sample_x = start_x; sample_x < stop_x; sample_x += params.SourceSize.z) {
        vec3 upper_sample = textureLod(Filtered, vec2(sample_x, upper_sample_y), 0.0).rgb;
        vec3 upper_width_rcp = textureLod(Source, vec2(sample_x, upper_sample_y), 0.0).rgb;
        vec3 lower_sample = textureLod(Filtered, vec2(sample_x, lower_sample_y), 0.0).rgb;
        vec3 lower_width_rcp = textureLod(Source, vec2(sample_x, lower_sample_y), 0.0).rgb;
        value += spot(upper_sample, upper_width_rcp, distance_x, upper_distance_y);
        value += spot(lower_sample, lower_width_rcp, distance_x, lower_distance_y);
        distance_x += delta;
    }
    FragColor = vec4(delta * value, 1.0);
}
