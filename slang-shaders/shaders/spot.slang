#version 450

layout(set = 0, binding = 0, std140) uniform UBO {
    mat4 MVP;
};

layout(push_constant) uniform Push {
    vec4 SourceSize;
    vec4 OutputSize;
    uint FrameCount;
    float InterMode;
    float InterSize;
    float OddFieldFirst;
    float ReferenceLines;
    float MaxSpotSize;
    float MinSpotSize;
    float OverscanHorizontal;
    float OverscanVertical;
    float MaskType;
    float MaskStagger;
    float MaskMin;
    float MaskMax;
    float SubpixelLayout;
} params;

#pragma parameter InterMode "Interlace/VGA doubling mode (0:off, 1:inter, 2:VGA)" 1.0 0.0 2.0 1.0
#pragma parameter InterSize "Interlace/VGA doubling trigger resolution" 320.0 160.0 1024.0 16.0
#pragma parameter OddFieldFirst "Interlacing Phase (odd field first)" 0.0 0.0 1.0 1.0
#pragma parameter ReferenceLines "Reference number of scanlines (0:adaptive)" 0.0 0.0 1200.0 16.0
#pragma parameter MaxSpotSize "Maximum spot size (proportion of reference scanline)" 0.95 0.25 1.0 0.05
#pragma parameter MinSpotSize "Minimum spot size (proportion of maximum)" 0.5 0.1 1.0 0.05
#pragma parameter OverscanHorizontal "Horizontal overscan (proportion to crop)" 0.0 0.0 0.1 0.01
#pragma parameter OverscanVertical "Vertical overscan (proportion to crop)" 0.0 0.0 0.1 0.01

#pragma parameter MaskType "Mask Pattern (0:2px, 1:2px slot, 2:4px)" 0.0 0.0 2.0 1.0
#pragma parameter MaskStagger "    Stagger every x lines" 0.0 -4.0 4.0 1.0
#pragma parameter MaskMin "    Minimum transparency" 0.0 0.0 1.0 0.05
#pragma parameter MaskMax "    Maximum transparency" 1.0 0.0 1.0 0.05
#pragma parameter SubpixelLayout "Subpixel layout (0:RGB, 1:BGR, 2:RBG, 3:[B&W])" 0.0 0.0 2.0 1.0

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

#include "mask.h"

vec3 spot(vec3 sample_value, vec3 width_rcp, float distance_x, float distance_y) {
    vec3 x = clamp(abs(distance_x) * width_rcp, 0.0, 1.0);
    vec3 y = clamp(abs(distance_y) * width_rcp, 0.0, 1.0);
    vec3 w = max(vec3(1.0), width_rcp * width_rcp); // correct gamma for scanline width, allowing bloom on overlap
    return sample_value * w * ((x * x) * (2.0 * x - 3.0) + 1.0) * ((y * y) * (2.0 * y - 3.0) + 1.0);
}

void main() {
    // Handle overscan.
    vec2 pos = (1.0 - vec2(params.OverscanHorizontal, params.OverscanVertical)) * (vTexCoord - 0.5) + 0.5;
    vec4 FrameSize = params.SourceSize;
    float videoLines = FrameSize.y;

    // Sample locations in Source texel space: [0, SourceSize.y), snapped to the
    // middle of a texel.
    float upper_sample_y, lower_sample_y;
    // Distance units are *scanlines heights*. delta is the distance between
    // samples on the x-axis, and has to be adjusted by the aspect ratio.
    // Overscan changes the aspect ratio and needs to be taken into account.
    float delta, upper_distance_y;
    // Check if we should be interlacing. If we are, grab two closest even or
    // odd lines. If we aren't, just grab the two closest lines.
    if (params.InterMode == 1.0 && FrameSize.y > params.InterSize) { // interlacing
        videoLines *= 0.5;
        if ((params.FrameCount + (params.OddFieldFirst > 0.5 ? 1u : 0u)) % 2u == 0u) {
            upper_sample_y = floor(ceil(pos.y * FrameSize.y + 0.5) * 0.5) * 2.0 + 0.5;
        } else {
            upper_sample_y = floor(floor(pos.y * FrameSize.y + 0.5) * 0.5) * 2.0 + 1.5;
        }
        lower_sample_y = upper_sample_y - 2.0;
        // TODO 0.5 doesn't quite work with an odd number of lines. Does that ever happen?
        delta = 0.5 * params.OutputSize.x * params.OutputSize.w *
                FrameSize.y * FrameSize.z *
                (1 - params.OverscanVertical) / (1 - params.OverscanHorizontal);
        upper_distance_y = 0.5 * (upper_sample_y - pos.y * FrameSize.y);
    } else {
        // double scan low resolution in VGA mode
        if (params.InterMode == 2.0 && params.SourceSize.y < params.InterSize) FrameSize *= vec4(1.0, 2.0, 1.0, 0.5);

        upper_sample_y = round(pos.y * FrameSize.y) + 0.5;
        lower_sample_y = upper_sample_y - 1.0;
        delta = params.OutputSize.x * params.OutputSize.w *
                FrameSize.y * FrameSize.z *
                (1 - params.OverscanVertical) / (1 - params.OverscanHorizontal);
        upper_distance_y = upper_sample_y - pos.y * FrameSize.y;
    }
    float lower_distance_y = upper_distance_y - 1.0;

    float maxSpotSize = params.MaxSpotSize;
    if (params.ReferenceLines > 0.0) {
        maxSpotSize = params.MaxSpotSize * sqrt(videoLines / params.ReferenceLines);
    }

    // Transform *_sample_y into [0,1] coordinate space. We need them for the
    // texture sampling below.
    upper_sample_y *= FrameSize.w;
    lower_sample_y *= FrameSize.w;

    vec3 value = vec3(0.0);
    float start_x = FrameSize.z * (round(pos.x * FrameSize.x - (maxSpotSize / delta)) + 0.5);
    float stop_x = FrameSize.z * round(pos.x * FrameSize.x + (maxSpotSize / delta));
    float distance_x = delta * FrameSize.x * (start_x - pos.x);
    float mask_num = 0.0;
    float mask_den = 0.0;
    for (float sample_x = start_x; sample_x < stop_x; sample_x += FrameSize.z) {
        vec3 upper_sample = textureLod(Filtered, vec2(sample_x, upper_sample_y), 0.0).rgb;
        vec3 lower_sample = textureLod(Filtered, vec2(sample_x, lower_sample_y), 0.0).rgb;
        vec4 upper_width_rcp = textureLod(Source, vec2(sample_x, upper_sample_y), 0.0);
        vec4 lower_width_rcp = textureLod(Source, vec2(sample_x, lower_sample_y), 0.0);
        value += spot(upper_sample, upper_width_rcp.rgb, distance_x, upper_distance_y);
        value += spot(lower_sample, lower_width_rcp.rgb, distance_x, lower_distance_y);
        distance_x += delta;
        mask_num += 2.0;
        mask_den += upper_width_rcp.a;
        mask_den += lower_width_rcp.a;
    }
    float dark = mix(params.MaskMin, params.MaskMax, mask_num/mask_den);
    vec3 msk = mask(
            floor(vTexCoord.xy * params.OutputSize.xy),
            dark,
            int(params.MaskType),
            int(params.MaskStagger));

    if (params.SubpixelLayout == 1.0) msk = msk.bgr;
    if (params.SubpixelLayout == 2.0) msk = msk.rbg;
    else if (params.SubpixelLayout == 3.0) msk = vec3(0.2126 * msk.r + 0.7152 * msk.g + 0.0722 * msk.b);

    FragColor = vec4(delta * msk * value, 1.0);
}
