
vec3 mask(vec2 coord, float dark, int type, int stagger)
{
    type = clamp(type, 0, 2);
    const float mwidths[3] = float[3] (2.0, 2.0, 4.0); 
    float mwidth = mwidths[type];
    if (stagger > 0.0) coord.x += 0.5*mwidth*floor(mod(coord.y, 2.0*stagger)/stagger);
    if (stagger < 0.0) coord.x += 2.0*floor(mod(coord.y, -2.0*stagger)/stagger);

    vec3 res = vec3(dark);

    // 3 phospors per 2 pixels
    // [MG]
    if (type == 0) {
        float px = mod(coord.x, 2.0);
        vec3 m = vec3(1.0, dark, 1.0);
        vec3 g = vec3(dark, 1.0, dark);
        res = px < 0.5 ? m : g;
    }

    // 3 phospors per 2 pixels
    // subpixel slotmask (or maybe pentile)
    // [MGMG]
    // [BGRK]
    // [MGMG]
    // [RKBG]
    else if (type == 1) {
        if (mod(coord.y, 2.0) < 0.5) {
            float px = mod(coord.x, 2.0);
            vec3 m = vec3(1.0, dark, 1.0);
            vec3 g = vec3(dark, 1.0, dark);
            res = px < 0.5 ? m : g;
        } else {
            coord.xy = floor(coord.xy * vec2(1.0, 0.5));
            coord.x += coord.y*2.0;
            coord.x = fract(coord.x / 4.0);
            if      (coord.x < 0.25) res.b = 1.0;
            else if (coord.x < 0.5)  res.g = 1.0;
            else if (coord.x < 0.75) res.r = 1.0;
        }
    }

    // 3 phosphors per 4 pixels
    // [RYCB]
    else if (type == 2) {
        float px = fract(coord.x / 4.0);
        if      (px < 0.25) res.r = 1.0;
        else if (px < 0.5)  res.rg = vec2(1.0);
        else if (px < 0.75) res.gb = vec2(1.0);
        else                res.b = 1.0;
    } 

    // // slot mask
    // if (slot) {
    //     float h = slotHeight + 1.0;
    //     float px = mod(coord.x, 2.0*mwidth);
    //     float py = floor(mod(coord.y, h));
    //     if (px < mwidth && py == 0.0)
    //         res = min(res, dark);
    //     else if (px >= mwidth && py == floor(h/2.0))
    //         res = min(res, dark);
    // }

    return res;
}
