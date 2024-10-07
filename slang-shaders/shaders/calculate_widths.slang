#version 450

layout(set = 0, binding = 0, std140) uniform UBO {
    mat4 MVP;
};

layout(push_constant) uniform Push {
    vec4 SourceSize;
    float InterMode;
    float InterSize;
    float ReferenceLines;
    float MaxSpotSize;
    float MinSpotSize;
} params;

#pragma format R16G16B16A16_SFLOAT
#pragma parameter InterMode "Interlace/VGA doubling mode (0:off, 1:inter, 2:VGA)" 1.0 0.0 2.0 1.0
#pragma parameter InterSize "Interlace/VGA doubling trigger resolution" 320.0 160.0 1024.0 16.0
#pragma parameter ReferenceLines "Reference number of scanlines (0:adaptive)" 0.0 0.0 1200.0 16.0
#pragma parameter MaxSpotSize "Maximum spot size (proportion of reference scanline)" 0.95 0.25 1.0 0.05
#pragma parameter MinSpotSize "Minimum spot size (proportion of maximum)" 0.5 0.1 1.0 0.05

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

void main() {
    ivec2 pix_loc = ivec2(floor(vTexCoord * params.SourceSize.xy));
    vec3 s = texelFetch(Source, pix_loc, 0).rgb;

    float mul = 1.0;
    float maxSpotSize = params.MaxSpotSize;
    if (params.ReferenceLines > 0.0) {
        // ensure scanline width is unchanged in VGA or interlacing
        float w = params.InterMode == 1.0 && params.SourceSize.y > params.InterSize ? 2.0
                : params.InterMode == 2.0 && params.SourceSize.y < params.InterSize ? 0.5
                : 1.0;

        // Correct scanline width for changeable resolution
        // without correction: 2x lines = 1/2 spot size
        // in reality: 2x lines ~= 1/sqrt(2) spot size (assuming same vertical refresh)
        mul = sqrt(params.SourceSize.y / (w * params.ReferenceLines));

        maxSpotSize = mul * params.MaxSpotSize;
    }
    vec3 width = params.MinSpotSize * maxSpotSize - sqrt(s) * (params.MinSpotSize * maxSpotSize - maxSpotSize);
    /* vec3 width = params.MinSpotSize * params.MaxSpotSize - sqrt(s) * (params.MinSpotSize * params.MaxSpotSize - params.MaxSpotSize); */

    // compute mask strength with a box blur, save as alpha channel
    // TODO: should be able to do this in the vertex shader?
    vec3 s00 = texelFetch(Source, pix_loc + ivec2(-1,-1), 0).rgb;
    vec3 s10 = texelFetch(Source, pix_loc + ivec2(0,-1), 0).rgb;
    vec3 s20 = texelFetch(Source, pix_loc + ivec2(1,-1), 0).rgb;
    vec3 s01 = texelFetch(Source, pix_loc + ivec2(-1,0), 0).rgb;
    vec3 s11 = s;
    vec3 s21 = texelFetch(Source, pix_loc + ivec2(1,0), 0).rgb;
    vec3 s02 = texelFetch(Source, pix_loc + ivec2(-1,1), 0).rgb;
    vec3 s12 = texelFetch(Source, pix_loc + ivec2(0,1), 0).rgb;
    vec3 s22 = texelFetch(Source, pix_loc + ivec2(1,1), 0).rgb;
    s = 9.0/(s00 + s10 + s20 + s01 + s11 + s21 + s02 + s12 + s22);

    float mask_str = 3.0/(s.r + s.b + s.g);
    FragColor = vec4(1.0/width, 1.0/mask_str);
}
