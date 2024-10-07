#version 450

// NTSC-Adaptive
// based on Themaister's NTSC shader


layout(push_constant) uniform Push
{
   vec4 OutputSize;
   vec4 SourceSize;
   uint FrameCount;
   float quality, cust_fringing, cust_artifacting, ntsc_sat, ntsc_black, ntsc_bright, ntsc_gamma;
} params;

layout(std140, set = 0, binding = 0) uniform UBO
{
	mat4 MVP;
} global;

#pragma parameter ntsc-row1 "------------------------------------------------" 0.0 0.0 0.0 1.0
#pragma parameter quality "INFO --> A&F Values: Svideo = 0.0 | Composite = 1.0 | RF = 2.0" 0.0 0.0 0.0 1.0
#pragma parameter cust_artifacting "NTSC Artifacting Value" 1.0 0.0 5.0 0.1
#pragma parameter cust_fringing "NTSC Fringing Value" 1.0 0.0 5.0 0.1
#pragma parameter ntsc-row2 "------------------------------------------------" 0.0 0.0 0.0 1.0
#pragma parameter ntsc_sat "NTSC Color Saturation" 1.0 0.0 2.0 0.01
#pragma parameter ntsc_black "NTSC Black level (0=NTSC-J, 1=NTSC)" 1.0 0.0 1.0 1.0
#pragma parameter ntsc_bright "NTSC Brightness" 1.0 0.0 1.5 0.01
#pragma parameter ntsc_gamma "NTSC Filtering Gamma Correction" 1.0 0.25 2.5 0.025
#pragma parameter ntsc-row3 "------------------------------------------------" 0.0 0.0 0.0 1.0

#define PI 3.14159265

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;
layout(location = 1) out vec2 pix_no;
layout(location = 3) out float BRIGHTNESS;
layout(location = 4) out float SATURATION;
layout(location = 5) out float FRINGING;
layout(location = 6) out float ARTIFACTING;

void main()
{
    gl_Position = global.MVP * Position;
    vTexCoord = TexCoord;
    pix_no = floor(TexCoord * params.SourceSize.xy + 0.5);

    ARTIFACTING = params.cust_artifacting;
    FRINGING = params.cust_fringing;
    SATURATION = params.ntsc_sat;
    BRIGHTNESS = params.ntsc_bright;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 1) in vec2 pix_no;
layout(location = 2) in float phase;
layout(location = 3) in float BRIGHTNESS;
layout(location = 4) in float SATURATION;
layout(location = 5) in float FRINGING;
layout(location = 6) in float ARTIFACTING;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

#define mix_mat  mat3(                                  \
        BRIGHTNESS,  FRINGING/8.0,   FRINGING/8.0,      \
        ARTIFACTING, SATURATION,     0.0,               \
        ARTIFACTING, 0.0,            SATURATION)

bool wave (int p, int color)
{
    return ((color + p + 8) % 12 < 6);
}

void main()
{
    // extract NES native integer color
    vec3 c = texture(Source, vTexCoord).rgb;
    vec3 yiq = vec3(0.0);
    float lum = 0.0;
    int color =    int(floor((c.r * 15.0) + 0.5));
    int level =    int(floor((c.g *  3.0) + 0.5));
    int emphasis = int(floor((c.b *  7.0) + 0.5));

    // Nestopia: 00AAFF
    // FCEUmm: 00AAE6

    // Color 0xE and 0xF are black
    level = (color < 14) ? level : 1;

    ////////////////////////////////////
    // Levels from nesdev wiki
    // 1 IRE === 0.7125 mV
    // BLANK === 0 IRE
    // This is just blatantly wrong.
    // Someone badly misunderstood what an IRE was.
    ////////////////////////////////////
    // const float levels[8] = {
    //     -12., 0., 34., 80.,
    //     43., 74., 110., 110.
    // };

    ////////////////////////////////////
    // Levels like nesdev example code
    // 1 IRE === (WHITE - BLANK) / 100
    // BLANK === 0 IRE
    // This isn't really how automatic gain control works.
    ////////////////////////////////////
    // const float levels[8] = {
    //     -10.7, 0.0, 30.5, 72.1,
    //     38.6, 67.0, 100.0, 100.0
    // };

    ////////////////////////////////////
    // Levels from nesdev measurements, no gain control
    // 1 IRE === 0.7125 mV
    // GROUND === -40 IRE
    // This is how a specially-configured BVM might work.
    // No normal TV would ever do this.
    ////////////////////////////////////
    // const float levels[8] = {
    //     -8.0, 3.8, 37.5, 83.5,
    //     46.5, 77.9, 114.4, 114.4
    // };

    ////////////////////////////////////
    // Levels from nesdev measurements, gain controlled
    // 1 IRE === BLANK / 40
    // BLANK === 0 IRE
    // (c.f. Renesas AN9765 datasheet)
    // Very nice and saturated.
    ////////////////////////////////////
    const float levels[8] = {
        -10.8, 0.0, 30.8, 72.8,
        39.0, 67.7, 101.0, 101.0
    };

    float black = params.ntsc_black * 7.5;
    float white = 100.;
    float attenuation = 0.816;

    float low  = levels[level + 4 * int(color == 0)];
    float high = levels[level + 4 * int(color < 13)];

    // 12 clocks per color cycle, 8 clocks per pixel
    // shift 8 clocks each pixel
    // shift 4 clocks each line
    // shift 8 clocks on odd frames
    int start_clock = int(8.0*mod(pix_no.x, 3.0) + 4.0*mod(pix_no.y, 3.0) + 8.0*mod(params.FrameCount, 2.0));

    for (int p = start_clock; p < start_clock+8; p++)
    {
        // NES NTSC modulator (square wave between two voltage levels):
        float spot = wave(p, color) ? high : low;

        // De-emphasis bits attenuate a part of the signal:
        if ((bool(emphasis & 1) && wave(p, 12)) ||
                (bool(emphasis & 2) && wave(p, 4)) ||
                (bool(emphasis & 4) && wave(p, 8))) 
        {
            spot *= attenuation;
        }

        // Normalize:
        float v = (spot - black) / (white - black);

        // Apply contrast/brightness/crosstalk
        const float CONTRAST = 1.0;
        v = (v - 0.5) * CONTRAST + 0.5;
        lum += v/8.0;
        vec3 new_yiq = vec3(v/8.0) * mix_mat;

        // demodulate
        new_yiq.y *= cos((PI / 6.0) * p );
        new_yiq.z *= sin((PI / 6.0) * p );
        yiq += new_yiq;
    }

    FragColor = vec4(yiq, lum);
} 
