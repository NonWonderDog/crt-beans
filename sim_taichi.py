from imageio.v3 import imwrite, imread
import numpy as np
import skimage
import argparse
import multiprocessing as mp
import functools
from PIL import Image, ImageFilter
import taichi as ti
import taichi.math as tm


ti.init()


def srgb_to_gamma(img, out_gamma):
    """sRGB uint8 to simple gamma float"""
    out = img.astype(np.float32) / 255
    out = np.where(out <= 0.04045, out / 12.92, np.power((out + 0.055) / 1.055, 2.4))
    out = np.power(out, 1.0 / out_gamma)
    return out


def gamma_to_gamma(img, in_gamma, out_gamma):
    return np.power(np.power(np.clip(img, 0.0, 1.0), in_gamma), 1.0 / out_gamma)


def srgb_to_yiq(img, out_gamma):
    """sRGB uint8 to YIQ float"""
    out = img.astype(np.float32) / 255
    out = np.where(out <= 0.04045, out / 12.92, np.power((out + 0.055) / 1.055, 2.4))
    out = np.power(out, 1.0 / out_gamma)
    rgb2yiq = np.array([[0.30, 0.59, 0.11],
                        [0.599, -0.2773, -0.3217],
                        [0.213, -0.5251, 0.3121]])
    out = np.dot(out, rgb2yiq.T.copy())
    return out


def gamma_to_linear(img, in_gamma):
    """Simple gamma float to linear float"""
    return np.power(np.clip(img, 0.0, 1.0), in_gamma)


def yiq_to_linear(img, in_gamma):
    """YIQ float to linear float"""
    yiq2rgb = np.linalg.inv(np.array([[0.30, 0.59, 0.11],
                                      [0.599, -0.2773, -0.3217],
                                      [0.213, -0.5251, 0.3121]]))
    out = np.dot(img, yiq2rgb.T.copy())
    out = np.clip(out, 0.0, 1.0)
    out = np.power(out, in_gamma)
    return out


def linear_to_srgb(img):
    """Linear float to sRGB uint8"""
    out = np.where(img <= 0.0031308, img * 12.92, 1.055 * (np.power(np.clip(img, 0.0, 1.0), (1.0 / 2.4))) - 0.055)
    out = np.around(out * 255).astype(np.uint8)
    return out


@ti.func
def texelFetch(Source, vTexCoords: tm.ivec2) -> tm.vec3:
    """Fetch pixel from img at (x, y), or 0 if outside range"""
    y_size, x_size = Source.shape
    val = tm.vec3(0.0)
    if not (vTexCoords.x < 0 or vTexCoords.x >= x_size or vTexCoords.y < 0 or vTexCoords.y >= y_size):
        val = Source[vTexCoords.y, vTexCoords.x]
    return val


@ti.func
def texture(Source, vTexCoords: tm.vec2) -> tm.vec3:
    """Sample from Source at (x, y) using bilinear interpolation.

    Outside of the Source is considered to be 0.
    """
    lookup_coords = vTexCoords.x * Source.shape
    coords = tm.round(lookup_coords, tm.ivec2)
    v11 = texelFetch(Source, coords)
    v01 = texelFetch(Source, coords - ivec2(1, 0))
    v10 = texelFetch(Source, coords - ivec2(0, 1))
    v00 = texelFetch(Source, coords - ivec2(1, 1))
    row1 = tm.mix(v10, v11, lookup_coords.y - coords.y + 0.5)
    row0 = tm.mix(v01, v00, lookup_coords.y - coords.y + 0.5)
    return tm.mix(row0, row1, lookup_coords.x - coords.x + 0.5)


def filter_fragment(image_in, output_dim):
    (in_height, in_width, in_planes) = image_in.shape
    (out_height, out_width, out_planes) = output_dim
    field_in = ti.Vector.field(n=3, dtype=float, shape=(in_height, in_width))
    field_in.from_numpy(image_in)
    field_out = ti.Vector.field(n=3, dtype=float, shape=(out_height, out_width))
    output_field = taichi_filter_fragment(field_in, field_out)
    return field_out.to_numpy()


@ti.kernel
def taichi_filter_fragment(field_in: ti.template(), field_out: ti.template()):
    (in_height, in_width) = field_in.shape
    (out_height, out_width) = field_out.shape
    SourceSize = tm.vec4(in_width, in_height, 1 / in_width, 1 / in_height)
    for y, x in field_out:
        vTexCoord = tm.vec2((x + 0.5) / out_width, (y + 0.5) / out_height)
        field_out[y, x] = filter_sim(vTexCoord, field_in, SourceSize)
    return


@ti.func
def filter_sim(vTexCoord: tm.vec2, Source, SourceSize: tm.vec4) -> tm.vec3:
    max_L = tm.max(tm.max(L.r, L.g), L.b)
    L_rcp = 1.0 / L

    filtered = tm.vec3(0.0)
    pix_y = int(tm.floor(vTexCoord.y * SourceSize.y))
    t = vTexCoord.x
    for pix_x in range(int(tm.floor(SourceSize.x * (vTexCoord.x - max_L))),
                       int(tm.floor(SourceSize.x * (vTexCoord.x + max_L))) + 1):
        s = texelFetch(Source, tm.ivec2(pix_x, pix_y))
        t0 = tm.vec3(pix_x * SourceSize.z)
        t1 = t0 + tm.vec3(SourceSize.z)
        t0 = tm.clamp(t0, t - L, t + L)
        t1 = tm.clamp(t1, t - L, t + L)
        # Integral of s * (1 / L) * (0.5 + 0.5 * cos(PI * (t - t_x) / L)) dt_x over t0 to t1
        filtered += 0.5 * s * L_rcp * (t1 - t0 + (L / np.pi) *
                                       (tm.sin(L_rcp * ((np.pi * t) - np.pi * t0)) - tm.sin(L_rcp * ((np.pi * t) - np.pi * t1))))
    return filtered


def spot_fragment(image_in, output_dim):
    (in_height, in_width, in_planes) = image_in.shape
    (out_height, out_width, out_planes) = output_dim
    field_in = ti.Vector.field(n=3, dtype=float, shape=(in_height, in_width))
    field_in.from_numpy(image_in)
    field_out = ti.Vector.field(n=3, dtype=float, shape=(out_height, out_width))
    output_field = taichi_spot_fragment(field_in, field_out)
    return field_out.to_numpy()


@ti.kernel
def taichi_spot_fragment(field_in: ti.template(), field_out: ti.template()):
    (in_height, in_width) = field_in.shape
    (out_height, out_width) = field_out.shape
    SourceSize = tm.vec4(in_width, in_height, 1 / in_width, 1 / in_height)
    OutputSize = tm.vec4(out_width, out_height, 1 / out_width, 1 / out_height)
    for y, x in field_out:
        vTexCoord = tm.vec2((x + 0.5) / out_width, (y + 0.5) / out_height)
        field_out[y, x] = spot_sim(vTexCoord, field_in, SourceSize, OutputSize)
    return


@ti.func
def spot_sim(vTexCoord: tm.vec2, img, SourceSize: tm.vec4, OutputSize: tm.vec4) -> tm.vec3:
    # Overscan
    vTexCoord = (1.0 - tm.vec2(OVERSCAN_HORIZONTAL, OVERSCAN_VERTICAL)) * (vTexCoord - 0.5) + 0.5

    # Distance units (including for delta) are *scanlines heights*. This means
    # we need to adjust x distances by the aspect ratio. Overscan needs to be
    # taken into account because it can change the aspect ratio.
    upper_sample_y = int(tm.round(vTexCoord.y * SourceSize.y))
    lower_sample_y = upper_sample_y - 1
    delta = OutputSize.x * OutputSize.w * SourceSize.y * SourceSize.z * (1 - OVERSCAN_VERTICAL) / (1 - OVERSCAN_HORIZONTAL)
    upper_distance_y = (upper_sample_y + 0.5) - vTexCoord.y * SourceSize.y
    lower_distance_y = (lower_sample_y + 0.5) - vTexCoord.y * SourceSize.y

    output = tm.vec3(0.0)
    for sample_x in range(int(tm.round(vTexCoord.x * SourceSize.x - (MAX_SPOT_SIZE / delta))),
                          int(tm.round(vTexCoord.x * SourceSize.x + (MAX_SPOT_SIZE / delta)))):
        upper_sample = texelFetch(img, tm.ivec2(sample_x, upper_sample_y))
        lower_sample = texelFetch(img, tm.ivec2(sample_x, lower_sample_y))
        distance_x = delta * ((sample_x + 0.5) - vTexCoord.x * SourceSize.x)
        output += spot3(upper_sample, distance_x, upper_distance_y)
        output += spot3(lower_sample, distance_x, lower_distance_y)
    return delta * output


@ti.func
def spot1(sample, distance_x, distance_y):
    width_rcp = 1.0 / tm.mix(MAX_SPOT_SIZE * MIN_SPOT_SIZE, MAX_SPOT_SIZE, tm.sqrt(sample))
    x = tm.clamp(abs(distance_x) * width_rcp, 0.0, 1.0)
    y = tm.clamp(abs(distance_y) * width_rcp, 0.0, 1.0)
    return sample * width_rcp * (0.5 * tm.cos(np.pi * x) + 0.5) * (0.5 * tm.cos(np.pi * y) + 0.5)


@ti.func
def spot2(sample, distance_x, distance_y):
    width_rcp = 1.0 / tm.mix(MAX_SPOT_SIZE * MIN_SPOT_SIZE, MAX_SPOT_SIZE, tm.sqrt(sample))
    x = tm.min(abs(distance_x) * width_rcp - 0.5, 0.5)
    y = tm.min(abs(distance_y) * width_rcp - 0.5, 0.5)
    return sample * width_rcp * (2.0 * (x * abs(x) - x) + 0.5) * (2.0 * (y * abs(y) - y) + 0.5)


@ti.func
def spot3(sample, distance_x, distance_y):
    width_rcp = 1.0 / tm.mix(MAX_SPOT_SIZE * MIN_SPOT_SIZE, MAX_SPOT_SIZE, tm.sqrt(sample))
    x = tm.clamp(abs(distance_x) * width_rcp, 0.0, 1.0)
    y = tm.clamp(abs(distance_y) * width_rcp, 0.0, 1.0)
    return sample * width_rcp * ((x * x) * (2.0 * x - 3.0) + 1.0) * ((y * y) * (2.0 * y - 3.0) + 1.0)


f16vec3 = ti.types.vector(3, ti.f16)


@ti.func
def spot_sim_f16(vTexCoord: tm.vec2, img, SourceSize: tm.vec4, OutputSize: tm.vec4) -> tm.vec3:
    # Overscan
    vTexCoord = (1.0 - tm.vec2(OVERSCAN_HORIZONTAL, OVERSCAN_VERTICAL)) * (vTexCoord - 0.5) + 0.5

    # Distance units (including for delta) are *scanlines heights*. This means
    # we need to adjust x distances by the aspect ratio. Overscan needs to be
    # taken into account because it can change the aspect ratio.
    # Check if we should be deinterlacing.
    upper_sample_y = int(tm.round(vTexCoord.y * SourceSize.y))
    lower_sample_y = upper_sample_y - 1
    delta = OutputSize.x * OutputSize.w * SourceSize.y * SourceSize.z * (1 - OVERSCAN_VERTICAL) / (1 - OVERSCAN_HORIZONTAL)
    upper_distance_y = ti.f16((upper_sample_y + 0.5) - vTexCoord.y * SourceSize.y)
    lower_distance_y = ti.f16((lower_sample_y + 0.5) - vTexCoord.y * SourceSize.y)

    output = tm.vec3(0.0)
    for sample_x in range(int(tm.round(vTexCoord.x * SourceSize.x - (MAX_SPOT_SIZE / delta))),
                          int(tm.round(vTexCoord.x * SourceSize.x + (MAX_SPOT_SIZE / delta)))):
        upper_sample = f16vec3(texelFetch(img, tm.ivec2(sample_x, upper_sample_y)))
        lower_sample = f16vec3(texelFetch(img, tm.ivec2(sample_x, lower_sample_y)))
        distance_x = ti.f16(delta * ((sample_x + 0.5) - vTexCoord.x * SourceSize.x))
        output += spot3_float16(upper_sample, distance_x, upper_distance_y)
        output += spot3_float16(lower_sample, distance_x, lower_distance_y)
    return delta * output


@ti.func
def spot3_float16(sample: f16vec3, distance_x: f16vec3, distance_y: f16vec3) -> f16vec3:
    width_rcp = ti.f16(1.0) / tm.mix(MAX_SPOT_SIZE * MIN_SPOT_SIZE, MAX_SPOT_SIZE, tm.sqrt(sample))
    x = tm.clamp(abs(distance_x) * width_rcp, ti.f16(0.0), ti.f16(1.0))
    y = tm.clamp(abs(distance_y) * width_rcp, ti.f16(0.0), ti.f16(1.0))
    return sample * width_rcp * \
            ((x * x) * (ti.f16(2.0) * x - ti.f16(3.0)) + ti.f16(1.0)) * \
            ((y * y) * (ti.f16(2.0) * y - ti.f16(3.0)) + ti.f16(1.0))


def box_blur(image_in, radius):
    """Do several box blurs on the image, approximating a gaussian blur.

    This is a very fast blur for large images. The speed is not
    dependent on the radius."""
    (in_height, in_width, in_planes) = image_in.shape
    field_in = ti.Vector.field(n=3, dtype=float, shape=(in_height, in_width))
    field_in.from_numpy(image_in)
    field_out = ti.Vector.field(n=3, dtype=float, shape=(in_width, in_height))
    for i in range(4):
        taichi_box_blur(field_in, field_out, radius)
        taichi_box_blur(field_out, field_in, radius)
    return field_in.to_numpy()


@ti.kernel
def taichi_box_blur(field_in: ti.template(), field_out: ti.template(), radius: int):
    """Do a 1D horizontal box blur on field_in, writing the transposed result to field_out"""
    (in_height, in_width) = field_in.shape
    width = 2 * radius + 1
    for y in range(in_height):
        running_sum = tm.vec3(0.0)
        # TODO If radius or width is > in_width?
        for x in range(radius):
            running_sum += field_in[y, x]
        for x in range(radius, width):
            running_sum += field_in[y, x]
            field_out[x - radius, y] = running_sum / width
        for x in range(width, in_width):
            running_sum += field_in[y, x]
            running_sum -= field_in[y, x - width]
            field_out[x - radius, y] = running_sum / width
        for x in range(in_width, in_width + radius):
            running_sum -= field_in[y, x - width]
            field_out[x - radius, y] = running_sum / width
    return


def gaussian_blur(image_in, sigma):
    (in_height, in_width, in_planes) = image_in.shape
    field_in = ti.Vector.field(n=3, dtype=float, shape=(in_height, in_width))
    field_in.from_numpy(image_in)
    field_out = ti.Vector.field(n=3, dtype=float, shape=(in_width, in_height))
    gaussian_fragment(field_in, field_out, sigma)
    gaussian_fragment(field_out, field_in, sigma)
    return field_in.to_numpy()


@ti.kernel
def gaussian_fragment(field_in: ti.template(), field_out: ti.template(), sigma: float):
    (in_height, in_width) = field_in.shape
    (out_height, out_width) = field_out.shape
    SourceSize = tm.vec4(in_width, in_height, 1 / in_width, 1 / in_height)
    OutputSize = tm.vec4(out_width, out_height, 1 / out_width, 1 / out_height)
    for y, x in field_out:
        vTexCoord = tm.vec2((x + 0.5) / out_width, (y + 0.5) / out_height)
        field_out[y, x] = gaussian_taichi(vTexCoord, field_in, SourceSize, OutputSize, sigma)
    return


@ti.func
def gaussian_taichi(vTexCoord: tm.vec2, Source, SourceSize: tm.vec4, OutputSize: tm.vec4, sigma: float) -> tm.vec3:
    pos = vTexCoord.yx * SourceSize.xy
    weight_sum = 0.0
    value = tm.vec3(0.0)
    center = tm.ivec2(int(tm.round(pos.x)), int(tm.floor(pos.y)))
    for x in range(center.x - int(tm.ceil(4 * sigma)), center.x + int(tm.ceil(4 * sigma)) + 1):
        distance_x = pos.x - x - 0.5
        weight = tm.exp(-(distance_x * distance_x) / (2 * sigma * sigma))
        weight_sum += weight
        value += weight * texelFetch(Source, tm.ivec2(x, center.y))
    return value / weight_sum


USE_YIQ = False
GAMMA = 2.4
# -6dB cutoff is at 1 / 2L in cycles. We want CUTOFF * 53.33e-6 cycles (CUTOFF bandwidth and NTSC standard active line time of 53.33us).
# CUTOFF = np.array([5.0e6, 0.6e6, 0.6e6])  # Hz
CUTOFF = np.array([2.6e6, 2.6e6, 2.6e6])  # Hz
# L = 1 / (CUTOFF * 53.33e-6 * 2)
Lnp = 1 / (CUTOFF * 53.33e-6 * 2)
L = tm.vec3(Lnp[0], Lnp[1], Lnp[2])
OUTPUT_RESOLUTION = (2160, 2880)  #(2160, 2880)  #(800, 1067)  #(720, 960)  #(1080, 1440) #(8640, 11520)
MAX_SPOT_SIZE= 0.95
MIN_SPOT_SIZE= 0.5
MASK_AMOUNT = 0.0
BLUR_SIGMA = 0.04
BLUR_AMOUNT = 0.15  #0.13
SAMPLES = 9000 #2880  #907  #1400
INTERLACING = True
INTERLACING_EVEN = False
OVERSCAN_HORIZONTAL = 0.05
OVERSCAN_VERTICAL = 0.05


def main():
    print('L = {}'.format(L))

    parser = argparse.ArgumentParser(description='Generate a CRT-simulated image')
    parser.add_argument('input')
    parser.add_argument('output')
    args = parser.parse_args()

    # Read image
    img_original = imread(args.input)
    image_height, image_width, planes = img_original.shape

    # To CRT gamma
    if USE_YIQ:
        img_crt_gamma = srgb_to_yiq(img_original, GAMMA)
    else:
        #img_crt_gamma = srgb_to_gamma(img_original, GAMMA)
        #img_crt_gamma = gamma_to_gamma(img_original.astype(np.float32) / 255, 2.2, GAMMA)
        img_crt_gamma = img_original.astype(np.float32) / 255

    # Horizontal low pass filter
    print('Low pass filtering...')
    img_filtered = filter_fragment(img_crt_gamma, (image_height, SAMPLES, 3))
    imwrite('filtered.png', linear_to_srgb(img_filtered))  # DEBUG

    # DEBUG -- Write Y, I, and Q planes to separate images
    # y_mask = np.array([True, False, False])
    # i_mask = np.array([False, True, False])
    # q_mask = np.array([False, False, True])
    # y = img_filtered.copy()
    # y[:, :, i_mask] = 0
    # y[:, :, q_mask] = 0
    # imwrite('y.png', linear_to_srgb(yiq_to_linear(y, GAMMA)))
    # i = img_filtered.copy()
    # i[:, :, y_mask] = 0.5
    # i[:, :, q_mask] = 0
    # imwrite('i.png', linear_to_srgb(yiq_to_linear(i, GAMMA)))
    # q = img_filtered.copy()
    # q[:, :, y_mask] = 0.5
    # q[:, :, i_mask] = 0
    # imwrite('q.png', linear_to_srgb(yiq_to_linear(q, GAMMA)))

    # To linear RGB
    if USE_YIQ:
        img_filtered_linear = yiq_to_linear(img_filtered, GAMMA)
    else:
        img_filtered_linear = gamma_to_linear(img_filtered, GAMMA)

    # Mimic CRT spot
    print('Simulating CRT spot...')
    img_spot = spot_fragment(img_filtered_linear, (OUTPUT_RESOLUTION[0], OUTPUT_RESOLUTION[1], 3))

    # Mask
    print('Masking...')
    #mask_resized = imread('mask_slot_distort.png').astype(np.float32) / 255.0  # 65535.0
    #mask_resized = mask_resized / np.max(mask_resized)
    #img_masked = img_spot * ((1 - MASK_AMOUNT) + mask_resized[:, :, 0:3] * MASK_AMOUNT)

    # mask = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]])
    # mask_resized = np.broadcast_to(mask[np.arange(OUTPUT_RESOLUTION[1]) % mask.shape[0]], (OUTPUT_RESOLUTION[0], OUTPUT_RESOLUTION[1], 3))
    # img_masked = img_spot * ((1 - MASK_AMOUNT) + mask_resized * MASK_AMOUNT)

    img_masked = img_spot

    # mask_tile = imread('mask.png').astype(np.float32) / 255.0
    # mask = np.tile(mask_tile, ((2 * 250 * 3 // 4), 250, 1))
    # imwrite('mask_fullsized.png', linear_to_srgb(mask))
    # # We have to resize each plane individually because pillow doesn't support
    # # multiple-channel, floating point images.
    # mask_red = mask[:, :, 0]
    # mask_green = mask[:, :, 1]
    # mask_blue = mask[:, :, 2]
    # mask_resized = np.zeros((2160, 2880, 3))
    # mask_resized[:, :, 0] = np.array(Image.fromarray(mask_red, mode='F').resize((2880, 2160), resample=Image.Resampling.LANCZOS))
    # mask_resized[:, :, 1] = np.array(Image.fromarray(mask_green, mode='F').resize((2880, 2160), resample=Image.Resampling.LANCZOS))
    # mask_resized[:, :, 2] = np.array(Image.fromarray(mask_blue, mode='F').resize((2880, 2160), resample=Image.Resampling.LANCZOS))
    # mask_resized = mask_resized / np.max(mask_resized)
    # mask_resized = np.minimum(mask_resized, 0)
    # imwrite('mask_resized.png', linear_to_srgb(mask_resized))
    # img_masked = mask_resized * img_spot

    # Diffusion
    print('Blurring...')
    sigma = BLUR_SIGMA * OUTPUT_RESOLUTION[0]
    # box_radius = int(np.round((np.sqrt(3 * sigma * sigma + 1) - 1) / 2))
    # blurred = box_blur(img_masked, box_radius)
    # blurred = skimage.filters.gaussian(img_masked, sigma=sigma, mode='constant', preserve_range=True, channel_axis=-1)
    blurred = gaussian_blur(img_masked, sigma=sigma)
    #imwrite('blurred.png', linear_to_srgb(blurred))  # DEBUG
    img_diffused = img_masked + (blurred - img_masked) * BLUR_AMOUNT
    #img_diffused = img_masked

    # To sRGB
    print('Color transform and save...')
    img_final_srgb = linear_to_srgb(img_diffused)

    imwrite(args.output, img_final_srgb)


if __name__ == '__main__':
    main()
