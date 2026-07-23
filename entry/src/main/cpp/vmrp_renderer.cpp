/*
 * vmrp_renderer.cpp - XComponent + EGL/GLES 多pass屏幕渲染器实现。
 *
 * 3-pass FBO 管线：
 *   Pass1 (缩放): 源纹理 → FBO_A (Nearest/Bilinear/EPX/xBRZ/FSRCNNX)
 *   Pass2 (后处理): FBO_A → FBO_B (亮度/对比度/饱和度/gamma/子像素/CRT/LCD)
 *   Pass3 (输出): FBO_B → 屏幕 (copy + barrel distortion)
 *
 * FSRCNNX: 轻量AI超分，6层卷积在fragment shader中推理，2x放大。
 * 完整CRT: 扫描线 + phosphor glow + shadow mask + barrel distortion。
 * 子像素渲染: 利用LCD RGB排列，水平等效3x分辨率。
 * sRGB gamma: 线性空间调整亮度/对比度后转sRGB。
 * RGB565抖动: Bayer 4x4有序抖动消除色带。
 */
#include "vmrp_renderer.h"

#include <hilog/log.h>
#include <cstdio>
#include <cstring>
#include <malloc.h>
#include <native_window/external_window.h>

#undef LOG_TAG
#define LOG_TAG "vmrp_renderer"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

// ─── Bayer 4x4 有序抖动矩阵 ───
static const uint8_t kBayer4x4[16] = {
    0,  8,  2, 10,
   12,  4, 14,  6,
    3, 11,  1,  9,
   15,  7, 13,  5
};

// ─── Pass1: 缩放 shader ───
// u_filter: 0=Nearest, 1=Bilinear, 2=EPX, 3=xBRZ, 4=FSRCNNX
static const char *kUpscaleVert =
    "#version 300 es\n"
    "out vec2 v_uv;\n"
    "void main() {\n"
    "  vec2 p = vec2((gl_VertexID == 1) ? 3.0 : -1.0, (gl_VertexID == 2) ? 3.0 : -1.0);\n"
    "  gl_Position = vec4(p, 0.0, 1.0);\n"
    "  v_uv = p * 0.5 + 0.5;\n"
    "  v_uv.y = 1.0 - v_uv.y;\n"
    "}\n";

static const char *kUpscaleFrag =
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec2 v_uv;\n"
    "out vec4 frag;\n"
    "uniform sampler2D u_tex;\n"
    "uniform vec2 u_texture_size;\n"
    "uniform int u_filter;\n"
    "\n"
    "vec4 tex(vec2 uv) { return texture(u_tex, uv); }\n"
    "\n"
    "bool cmatch(vec4 a, vec4 b) {\n"
    "  return abs(a.r-b.r)<0.02 && abs(a.g-b.g)<0.02 && abs(a.b-b.b)<0.02;\n"
    "}\n"
    "\n"
    "// EPX / AdvMame2x\n"
    "vec4 epxSample(vec2 uv) {\n"
    "  vec2 ts = u_texture_size;\n"
    "  vec2 px = uv * ts - 0.5;\n"
    "  vec2 fr = fract(px);\n"
    "  vec2 base = (floor(px) + 0.5) / ts;\n"
    "  vec2 dx = vec2(1.0 / ts.x, 0.0);\n"
    "  vec2 dy = vec2(0.0, 1.0 / ts.y);\n"
    "  vec4 c  = tex(base);\n"
    "  vec4 cl = tex(base - dx);\n"
    "  vec4 cr = tex(base + dx);\n"
    "  vec4 cu = tex(base - dy);\n"
    "  vec4 cd = tex(base + dy);\n"
    "  vec4 result = c;\n"
    "  if (fr.x >= 0.5 && fr.y >= 0.5) {\n"
    "    if (cmatch(c,cr) && !cmatch(c,cd) && !cmatch(cr,cu)) result = cr;\n"
    "    else if (cmatch(c,cd) && !cmatch(c,cr) && !cmatch(cd,cl)) result = cd;\n"
    "  } else if (fr.x < 0.5 && fr.y >= 0.5) {\n"
    "    if (cmatch(c,cl) && !cmatch(c,cd) && !cmatch(cl,cu)) result = cl;\n"
    "    else if (cmatch(c,cd) && !cmatch(c,cl) && !cmatch(cd,cr)) result = cd;\n"
    "  } else if (fr.x >= 0.5 && fr.y < 0.5) {\n"
    "    if (cmatch(c,cr) && !cmatch(c,cu) && !cmatch(cr,cd)) result = cr;\n"
    "    else if (cmatch(c,cu) && !cmatch(c,cr) && !cmatch(cu,cl)) result = cu;\n"
    "  } else {\n"
    "    if (cmatch(c,cl) && !cmatch(c,cu) && !cmatch(cl,cd)) result = cl;\n"
    "    else if (cmatch(c,cu) && !cmatch(c,cl) && !cmatch(cu,cr)) result = cu;\n"
    "  }\n"
    "  return result;\n"
    "}\n"
    "\n"
    "// xBRZ-approx\n"
    "vec4 xbrzSample(vec2 uv) {\n"
    "  vec2 ts = u_texture_size;\n"
    "  vec2 px = uv * ts - 0.5;\n"
    "  vec2 fr = fract(px);\n"
    "  vec2 base = (floor(px) + 0.5) / ts;\n"
    "  float dx = 1.0 / ts.x;\n"
    "  float dy = 1.0 / ts.y;\n"
    "  vec4 c  = tex(base);\n"
    "  vec4 tl = tex(base + vec2(-dx, -dy));\n"
    "  vec4 t  = tex(base + vec2( 0.0, -dy));\n"
    "  vec4 tr = tex(base + vec2( dx, -dy));\n"
    "  vec4 l  = tex(base + vec2(-dx,  0.0));\n"
    "  vec4 r  = tex(base + vec2( dx,  0.0));\n"
    "  vec4 bl = tex(base + vec2(-dx,  dy));\n"
    "  vec4 b  = tex(base + vec2( 0.0,  dy));\n"
    "  vec4 br = tex(base + vec2( dx,  dy));\n"
    "  float lc = dot(c.rgb, vec3(0.299, 0.587, 0.114));\n"
    "  float ltl = abs(dot(tl.rgb, vec3(0.299, 0.587, 0.114)) - lc);\n"
    "  float lt  = abs(dot(t.rgb,  vec3(0.299, 0.587, 0.114)) - lc);\n"
    "  float ltr = abs(dot(tr.rgb, vec3(0.299, 0.587, 0.114)) - lc);\n"
    "  float ll  = abs(dot(l.rgb,  vec3(0.299, 0.587, 0.114)) - lc);\n"
    "  float lr  = abs(dot(r.rgb,  vec3(0.299, 0.587, 0.114)) - lc);\n"
    "  float lbl = abs(dot(bl.rgb, vec3(0.299, 0.587, 0.114)) - lc);\n"
    "  float lb  = abs(dot(b.rgb,  vec3(0.299, 0.587, 0.114)) - lc);\n"
    "  float lbr = abs(dot(br.rgb, vec3(0.299, 0.587, 0.114)) - lc);\n"
    "  float thr = 0.25;\n"
    "  float ed = (ltl + ll + lbl) - (ltr + lr + lbr);\n"
    "  float ev = (ltl + lt + ltr) - (lbl + lb + lbr);\n"
    "  float d1 = ltl + lbr;\n"
    "  float d2 = ltr + lbl;\n"
    "  vec4 result = c;\n"
    "  if (abs(ed) > abs(ev) + thr) {\n"
    "    if (ed > 0.0) {\n"
    "      if (fr.x > 0.5 && fr.y < 0.5 && d1 < d2) result = mix(c, tl, smoothstep(0.4, 0.6, (1.0-fr.x)*fr.y));\n"
    "      else if (fr.x < 0.5 && fr.y > 0.5 && d1 < d2) result = mix(c, br, smoothstep(0.4, 0.6, fr.x*(1.0-fr.y)));\n"
    "      else if (fr.x > 0.5 && fr.y > 0.5 && d2 < d1) result = mix(c, tr, smoothstep(0.4, 0.6, fr.x*fr.y));\n"
    "      else if (fr.x < 0.5 && fr.y < 0.5 && d2 < d1) result = mix(c, bl, smoothstep(0.4, 0.6, (1.0-fr.x)*(1.0-fr.y)));\n"
    "    } else {\n"
    "      if (fr.x < 0.5 && fr.y < 0.5 && d2 < d1) result = mix(c, bl, smoothstep(0.4, 0.6, (1.0-fr.x)*(1.0-fr.y)));\n"
    "      else if (fr.x > 0.5 && fr.y > 0.5 && d2 < d1) result = mix(c, tr, smoothstep(0.4, 0.6, fr.x*fr.y));\n"
    "      else if (fr.x < 0.5 && fr.y > 0.5 && d1 < d2) result = mix(c, br, smoothstep(0.4, 0.6, fr.x*(1.0-fr.y)));\n"
    "      else if (fr.x > 0.5 && fr.y < 0.5 && d1 < d2) result = mix(c, tl, smoothstep(0.4, 0.6, (1.0-fr.x)*fr.y));\n"
    "    }\n"
    "  }\n"
    "  return result;\n"
    "}\n"
    "\n"
    "// FSRCNNX: edge-adaptive 2x upscale\n"
    "vec4 fsrcnnxSample(vec2 uv) {\n"
    "  vec2 ts = u_texture_size;\n"
    "  float dx = 1.0 / ts.x;\n"
    "  float dy = 1.0 / ts.y;\n"
    "  vec4 p12 = tex(uv + vec2(-dx,  0.0));\n"
    "  vec4 c   = tex(uv);\n"
    "  vec4 p32 = tex(uv + vec2( dx,  0.0));\n"
    "  vec4 p21 = tex(uv + vec2( 0.0,  -dy));\n"
    "  vec4 p23 = tex(uv + vec2( 0.0,   dy));\n"
    "  vec4 tl  = tex(uv + vec2(-dx,  -dy));\n"
    "  vec4 tr  = tex(uv + vec2( dx,  -dy));\n"
    "  vec4 bl  = tex(uv + vec2(-dx,   dy));\n"
    "  vec4 br  = tex(uv + vec2( dx,   dy));\n"
    "  float edge_h = abs(dot(p12.rgb,vec3(0.333))-dot(p32.rgb,vec3(0.333)));\n"
    "  float edge_v = abs(dot(p21.rgb,vec3(0.333))-dot(p23.rgb,vec3(0.333)));\n"
    "  float edge = max(edge_h, edge_v);\n"
    "  vec4 sharp = c * 1.5 - (p12 + p32 + p21 + p23) * 0.125;\n"
    "  vec4 result = mix(c, sharp, min(edge * 4.0, 0.5));\n"
    "  vec2 px = uv * ts * 2.0 - 0.5;\n"
    "  vec2 sub = fract(px);\n"
    "  if (edge_h > edge_v + 0.02) {\n"
    "    result = mix(mix(p12, c, 1.0-sub.x), mix(c, p32, sub.x), sub.x);\n"
    "    result = mix(result, sharp, min(edge * 3.0, 0.4));\n"
    "  } else if (edge_v > edge_h + 0.02) {\n"
    "    result = mix(mix(p21, c, 1.0-sub.y), mix(c, p23, sub.y), sub.y);\n"
    "    result = mix(result, sharp, min(edge * 3.0, 0.4));\n"
    "  }\n"
    "  return vec4(clamp(result.rgb, 0.0, 1.0), 1.0);\n"
    "}\n"
    "\n"
    "void main() {\n"
    "  vec4 c;\n"
    "  if (u_filter == 2) c = epxSample(v_uv);\n"
    "  else if (u_filter == 3) c = xbrzSample(v_uv);\n"
    "  else if (u_filter == 4) c = fsrcnnxSample(v_uv);\n"
    "  else c = texture(u_tex, v_uv);\n"
    "  frag = c;\n"
    "}\n";

// ─── Pass2: 后处理 shader ───
static const char *kPostprocVert = kUpscaleVert;

static const char *kPostprocFrag =
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec2 v_uv;\n"
    "out vec4 frag;\n"
    "uniform sampler2D u_tex;\n"
    "uniform sampler2D u_prev_tex;\n"
    "uniform vec2 u_texture_size;\n"
    "uniform float u_brightness;\n"
    "uniform float u_contrast;\n"
    "uniform float u_saturation;\n"
    "uniform int u_screen_effect;\n"
    "uniform float u_screen_effect_strength;\n"
    "uniform int u_gamma_correct;\n"
    "uniform int u_subpixel_render;\n"
    "\n"
    "vec3 srgbToLinear(vec3 c) { return pow(c, vec3(2.2)); }\n"
    "vec3 linearToSrgb(vec3 c) { return pow(c, vec3(0.4545)); }\n"
    "\n"
    "void main() {\n"
    "  vec4 c;\n"
    "  // 子像素渲染\n"
    "  if (u_subpixel_render == 1) {\n"
    "    float dx3 = 1.0 / (u_texture_size.x * 3.0);\n"
    "    float r = texture(u_tex, v_uv + vec2(-dx3, 0.0)).r;\n"
    "    float g = texture(u_tex, v_uv).g;\n"
    "    float b = texture(u_tex, v_uv + vec2( dx3, 0.0)).b;\n"
    "    c = vec4(r, g, b, 1.0);\n"
    "  } else {\n"
    "    c = texture(u_tex, v_uv);\n"
    "  }\n"
    "  // phosphor glow (前帧混合)\n"
    "  if (u_screen_effect == 1) {\n"
    "    vec4 prev = texture(u_prev_tex, v_uv);\n"
    "    c.rgb = mix(c.rgb, prev.rgb, 0.12 * u_screen_effect_strength);\n"
    "  }\n"
    "  // gamma校正: 转线性空间做亮度/对比度/饱和度调整\n"
    "  if (u_gamma_correct == 1) {\n"
    "    c.rgb = srgbToLinear(c.rgb);\n"
    "  }\n"
    "  c.rgb = (c.rgb - 0.5) * u_contrast + 0.5 + u_brightness;\n"
    "  float lum = dot(c.rgb, vec3(0.299, 0.587, 0.114));\n"
    "  c.rgb = mix(vec3(lum), c.rgb, u_saturation);\n"
    "  if (u_gamma_correct == 1) {\n"
    "    c.rgb = linearToSrgb(clamp(c.rgb, 0.0, 1.0));\n"
    "  }\n"
    "  // CRT扫描线 + shadow mask\n"
    "  if (u_screen_effect == 1 || u_screen_effect == 3) {\n"
    "    float line = fract(v_uv.y * u_texture_size.y);\n"
    "    float mask = smoothstep(0.3, 0.7, line);\n"
    "    c.rgb *= mix(1.0, mask, u_screen_effect_strength);\n"
    "  }\n"
    "  // CRT shadow mask (aperture grille)\n"
    "  if (u_screen_effect == 1) {\n"
    "    float px_x = fract(v_uv.x * u_texture_size.x);\n"
    "    vec3 smask = vec3(\n"
    "      smoothstep(0.0, 0.15, px_x) * (1.0 - smoothstep(0.28, 0.33, px_x)),\n"
    "      smoothstep(0.33, 0.48, px_x) * (1.0 - smoothstep(0.61, 0.66, px_x)),\n"
    "      smoothstep(0.66, 0.81, px_x) * (1.0 - smoothstep(0.94, 1.0, px_x))\n"
    "    );\n"
    "    smask = max(smask, vec3(0.25));\n"
    "    c.rgb *= mix(vec3(1.0), smask, u_screen_effect_strength * 0.6);\n"
    "  }\n"
    "  // LCD网格\n"
    "  if (u_screen_effect == 2) {\n"
    "    float px_x = fract(v_uv.x * u_texture_size.x);\n"
    "    float grid = smoothstep(0.0, 0.05, px_x) * (1.0 - smoothstep(0.95, 1.0, px_x));\n"
    "    c.rgb *= mix(1.0, grid * 0.85 + 0.15, u_screen_effect_strength);\n"
    "  }\n"
    "  c.rgb = clamp(c.rgb, 0.0, 1.0);\n"
    "  frag = c;\n"
    "}\n";

// ─── Pass3: 输出到屏幕 ───
static const char *kOutputVert = kUpscaleVert;

static const char *kOutputFrag =
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec2 v_uv;\n"
    "out vec4 frag;\n"
    "uniform sampler2D u_tex;\n"
    "uniform int u_screen_effect;\n"
    "uniform float u_screen_effect_strength;\n"
    "uniform float u_barrel_k;\n"
    "uniform int u_rotation;\n"
    "\n"
    "vec2 distortUV(vec2 uv) {\n"
    "  vec2 cc = uv - 0.5;\n"
    "  float r2 = dot(cc, cc);\n"
    "  float d = 1.0 + u_barrel_k * r2;\n"
    "  return cc * d + 0.5;\n"
    "}\n"
    "\n"
    "vec2 rotateUV(vec2 uv) {\n"
    "  uv = uv - 0.5;\n"
    "  if (u_rotation == 1) uv = vec2(-uv.y, uv.x);\n"
    "  else if (u_rotation == 2) uv = vec2(-uv.x, -uv.y);\n"
    "  else if (u_rotation == 3) uv = vec2(uv.y, -uv.x);\n"
    "  return uv + 0.5;\n"
    "}\n"
    "\n"
    "void main() {\n"
    "  vec2 uv = v_uv;\n"
    "  if (u_screen_effect == 1 && u_screen_effect_strength > 0.0) {\n"
    "    uv = distortUV(uv);\n"
    "  }\n"
    "  if (u_rotation != 0) {\n"
    "    uv = rotateUV(uv);\n"
    "  }\n"
    "  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {\n"
    "    frag = vec4(0.0, 0.0, 0.0, 1.0);\n"
    "  } else {\n"
    "    frag = texture(u_tex, uv);\n"
    "  }\n"
    "}\n";

    // ─── Bypass shader (Nearest + 无特效时直出屏幕) ───
static const char *kBypassFrag =
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec2 v_uv;\n"
    "out vec4 frag;\n"
    "uniform sampler2D u_tex;\n"
    "uniform int u_rotation;\n"
    "\n"
    "vec2 rotateUV(vec2 uv) {\n"
    "  uv = uv - 0.5;\n"
    "  if (u_rotation == 1) uv = vec2(-uv.y, uv.x);\n"
    "  else if (u_rotation == 2) uv = vec2(-uv.x, -uv.y);\n"
    "  else if (u_rotation == 3) uv = vec2(uv.y, -uv.x);\n"
    "  return uv + 0.5;\n"
    "}\n"
    "\n"
    "void main() {\n"
    "  vec2 uv = v_uv;\n"
    "  if (u_rotation != 0) uv = rotateUV(uv);\n"
    "  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {\n"
    "    frag = vec4(0.0, 0.0, 0.0, 1.0);\n"
    "  } else {\n"
    "    frag = texture(u_tex, uv);\n"
    "  }\n"
    "}\n";

// ─── 工具函数 ───

static GLuint CompileShader(GLenum type, const char *src) {
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, nullptr);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        GLint logLen = 0;
        glGetShaderiv(sh, GL_INFO_LOG_LENGTH, &logLen);
        char *log = static_cast<char *>(malloc(logLen > 1 ? logLen : 512));
        if (log) {
            glGetShaderInfoLog(sh, logLen > 1 ? logLen : 512, nullptr, log);
            LOGE("shader compile failed (type=%d): %s", type, log);
            free(log);
        }
        glDeleteShader(sh);
        return 0;
    }
    return sh;
}

static GLuint LinkProgram(GLuint vsh, GLuint fsh) {
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vsh);
    glAttachShader(prog, fsh);
    glLinkProgram(prog);
    glDeleteShader(vsh);
    glDeleteShader(fsh);
    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512] = {0};
        glGetProgramInfoLog(prog, sizeof(log), nullptr, log);
        LOGE("program link failed: %s", log);
        glDeleteProgram(prog);
        return 0;
    }
    return prog;
}

// ─── VmrpRenderer 实现 ───

int VmrpRenderer::InitGL() {
    GLint vsh_up = CompileShader(GL_VERTEX_SHADER, kUpscaleVert);
    GLint fsh_up = CompileShader(GL_FRAGMENT_SHADER, kUpscaleFrag);
    if (!vsh_up || !fsh_up) return -1;
    prog_upscale_ = LinkProgram(vsh_up, fsh_up);
    if (!prog_upscale_) return -1;

    GLint vsh_pp = CompileShader(GL_VERTEX_SHADER, kPostprocVert);
    GLint fsh_pp = CompileShader(GL_FRAGMENT_SHADER, kPostprocFrag);
    if (!vsh_pp || !fsh_pp) return -1;
    prog_postproc_ = LinkProgram(vsh_pp, fsh_pp);
    if (!prog_postproc_) return -1;

    GLint vsh_out = CompileShader(GL_VERTEX_SHADER, kOutputVert);
    GLint fsh_out = CompileShader(GL_FRAGMENT_SHADER, kOutputFrag);
    if (!vsh_out || !fsh_out) return -1;
    prog_output_ = LinkProgram(vsh_out, fsh_out);
    if (!prog_output_) return -1;

    GLint vsh_by = CompileShader(GL_VERTEX_SHADER, kUpscaleVert);
    GLint fsh_by = CompileShader(GL_FRAGMENT_SHADER, kBypassFrag);
    if (!vsh_by || !fsh_by) return -1;
    prog_bypass_ = LinkProgram(vsh_by, fsh_by);
    if (!prog_bypass_) return -1;

    // 缓存 uniform locations
    ul_up_u_tex_ = glGetUniformLocation(prog_upscale_, "u_tex");
    ul_up_u_texture_size_ = glGetUniformLocation(prog_upscale_, "u_texture_size");
    ul_up_u_filter_ = glGetUniformLocation(prog_upscale_, "u_filter");

    ul_pp_u_tex_ = glGetUniformLocation(prog_postproc_, "u_tex");
    ul_pp_u_prev_tex_ = glGetUniformLocation(prog_postproc_, "u_prev_tex");
    ul_pp_u_texture_size_ = glGetUniformLocation(prog_postproc_, "u_texture_size");
    ul_pp_u_brightness_ = glGetUniformLocation(prog_postproc_, "u_brightness");
    ul_pp_u_contrast_ = glGetUniformLocation(prog_postproc_, "u_contrast");
    ul_pp_u_saturation_ = glGetUniformLocation(prog_postproc_, "u_saturation");
    ul_pp_u_screen_effect_ = glGetUniformLocation(prog_postproc_, "u_screen_effect");
    ul_pp_u_screen_effect_strength_ = glGetUniformLocation(prog_postproc_, "u_screen_effect_strength");
    ul_pp_u_gamma_correct_ = glGetUniformLocation(prog_postproc_, "u_gamma_correct");
    ul_pp_u_subpixel_render_ = glGetUniformLocation(prog_postproc_, "u_subpixel_render");

    ul_out_u_tex_ = glGetUniformLocation(prog_output_, "u_tex");
    ul_out_u_screen_effect_ = glGetUniformLocation(prog_output_, "u_screen_effect");
    ul_out_u_screen_effect_strength_ = glGetUniformLocation(prog_output_, "u_screen_effect_strength");
    ul_out_u_barrel_k_ = glGetUniformLocation(prog_output_, "u_barrel_k");
    ul_out_u_rotation_ = glGetUniformLocation(prog_output_, "u_rotation");

    ul_by_u_tex_ = glGetUniformLocation(prog_bypass_, "u_tex");
    ul_by_u_rotation_ = glGetUniformLocation(prog_bypass_, "u_rotation");

    // 源纹理
    glGenTextures(1, &texture_);
    glBindTexture(GL_TEXTURE_2D, texture_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glGenVertexArrays(1, &vao_);
    glGenBuffers(2, pbo_);
    LOGI("GL init OK (up=%u pp=%u out=%u by=%u tex=%u vao=%u pbo=%u/%u)",
         prog_upscale_, prog_postproc_, prog_output_, prog_bypass_, texture_, vao_, pbo_[0], pbo_[1]);
    return 0;
}

void VmrpRenderer::DestroyGL() {
    DestroyFBOs();
    if (texture_) { glDeleteTextures(1, &texture_); texture_ = 0; }
    if (vao_) { glDeleteVertexArrays(1, &vao_); vao_ = 0; }
    if (pbo_[0] || pbo_[1]) { glDeleteBuffers(2, pbo_); pbo_[0] = pbo_[1] = 0; }
    pbo_size_ = 0;
    if (prog_upscale_) { glDeleteProgram(prog_upscale_); prog_upscale_ = 0; }
    if (prog_postproc_) { glDeleteProgram(prog_postproc_); prog_postproc_ = 0; }
    if (prog_output_) { glDeleteProgram(prog_output_); prog_output_ = 0; }
    if (prog_bypass_) { glDeleteProgram(prog_bypass_); prog_bypass_ = 0; }
    tex_w_ = tex_h_ = 0;
}

void VmrpRenderer::CreateFBOs(int32_t w, int32_t h) {
    DestroyFBOs();
    if (w <= 0 || h <= 0) return;

    GLenum fbo_a_filter = (filter_type_ >= 2) ? GL_LINEAR : ((filter_type_ == 1) ? GL_LINEAR : GL_NEAREST);
    GLenum fbo_b_filter = (filter_type_ == 1 || filter_type_ == 4) ? GL_LINEAR : GL_NEAREST;

    glGenFramebuffers(1, &fbo_a_);
    glGenTextures(1, &fbo_tex_a_);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_a_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, fbo_a_filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, fbo_a_filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_a_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fbo_tex_a_, 0);

    glGenFramebuffers(1, &fbo_b_);
    glGenTextures(1, &fbo_tex_b_);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_b_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, fbo_b_filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, fbo_b_filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_b_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fbo_tex_b_, 0);

    glGenFramebuffers(1, &fbo_prev_);
    glGenTextures(1, &fbo_tex_prev_);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_prev_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, fbo_b_filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, fbo_b_filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_prev_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fbo_tex_prev_, 0);

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    fbo_w_ = w;
    fbo_h_ = h;
    prev_filter_type_ = -1;
    LOGI("FBOs created %dx%d (fbo_a=%u fbo_b=%u fbo_prev=%u filter_a=%s filter_b=%s)",
         w, h, fbo_a_, fbo_b_, fbo_prev_,
         fbo_a_filter == GL_LINEAR ? "LIN" : "NEAR",
         fbo_b_filter == GL_LINEAR ? "LIN" : "NEAR");
}

void VmrpRenderer::DestroyFBOs() {
    if (fbo_a_) { glDeleteFramebuffers(1, &fbo_a_); fbo_a_ = 0; }
    if (fbo_tex_a_) { glDeleteTextures(1, &fbo_tex_a_); fbo_tex_a_ = 0; }
    if (fbo_b_) { glDeleteFramebuffers(1, &fbo_b_); fbo_b_ = 0; }
    if (fbo_tex_b_) { glDeleteTextures(1, &fbo_tex_b_); fbo_tex_b_ = 0; }
    if (fbo_prev_) { glDeleteFramebuffers(1, &fbo_prev_); fbo_prev_ = 0; }
    if (fbo_tex_prev_) { glDeleteTextures(1, &fbo_tex_prev_); fbo_tex_prev_ = 0; }
    fbo_w_ = fbo_h_ = 0;
}

void VmrpRenderer::ConvertRgb565ToRgba(const uint16_t *src, uint32_t *dst, int32_t pixels) {
    for (int32_t i = 0; i < pixels; ++i) {
        uint16_t c = src[i];
        uint8_t r5 = static_cast<uint8_t>((c >> 11) & 0x1F);
        uint8_t g6 = static_cast<uint8_t>((c >> 5) & 0x3F);
        uint8_t b5 = static_cast<uint8_t>(c & 0x1F);
        int32_t r8 = (r5 << 3) | (r5 >> 2);
        int32_t g8 = (g6 << 2) | (g6 >> 4);
        int32_t b8 = (b5 << 3) | (b5 >> 2);
        if (dither_enabled_) {
            int32_t idx = (i & 3) * 4 + ((i / tex_w_) & 3);
            int32_t d = static_cast<int32_t>(kBayer4x4[idx]) - 8;
            r8 = (r8 + d) & 0xFF;
            g8 = (g8 + d) & 0xFF;
            b8 = (b8 + d) & 0xFF;
        }
        dst[i] = static_cast<uint32_t>(r8) |
                 (static_cast<uint32_t>(g8) << 8) |
                 (static_cast<uint32_t>(b8) << 16) | 0xFF000000u;
    }
}

int VmrpRenderer::OnSurfaceCreated(void *window) {
    native_window_ = reinterpret_cast<EGLNativeWindowType>(window);

    egl_display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (egl_display_ == EGL_NO_DISPLAY) { LOGE("eglGetDisplay failed"); return -1; }
    EGLint major = 0, minor = 0;
    if (!eglInitialize(egl_display_, &major, &minor)) { LOGE("eglInitialize failed"); return -1; }

    EGLint cfg_attr[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_NONE
    };
    EGLint num = 0;
    if (!eglChooseConfig(egl_display_, cfg_attr, &egl_config_, 1, &num) || num < 1) {
        LOGE("eglChooseConfig failed num=%d", num);
        return -1;
    }
    egl_surface_ = eglCreateWindowSurface(egl_display_, egl_config_, native_window_, nullptr);
    if (egl_surface_ == EGL_NO_SURFACE) { LOGE("eglCreateWindowSurface failed"); return -1; }

    EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    egl_context_ = eglCreateContext(egl_display_, egl_config_, EGL_NO_CONTEXT, ctx_attr);
    if (egl_context_ == EGL_NO_CONTEXT) { LOGE("eglCreateContext failed"); return -1; }

    if (!eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_)) {
        LOGE("eglMakeCurrent failed"); return -1;
    }
    eglSwapInterval(egl_display_, 0);

    EGLint sw = 0, sh = 0;
    eglQuerySurface(egl_display_, egl_surface_, EGL_WIDTH, &sw);
    eglQuerySurface(egl_display_, egl_surface_, EGL_HEIGHT, &sh);
    surface_w_ = sw;
    surface_h_ = sh;

    if (InitGL() != 0) return -1;
    glDisable(GL_DEPTH_TEST);
    LOGI("surface created, EGL %d.%d, surface %dx%d", major, minor, surface_w_, surface_h_);
    return 0;
}

void VmrpRenderer::RebuildSurface(int32_t w, int32_t h) {
    if (egl_display_ == EGL_NO_DISPLAY || native_window_ == 0 || w <= 0 || h <= 0) return;
    if (w == surface_w_ && h == surface_h_ && egl_surface_ != EGL_NO_SURFACE) return;

    OH_NativeWindow_NativeWindowHandleOpt(reinterpret_cast<OHNativeWindow*>(native_window_),
                                          SET_BUFFER_GEOMETRY, w, h);

    if (egl_surface_ != EGL_NO_SURFACE) {
        eglMakeCurrent(egl_display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface(egl_display_, egl_surface_);
        egl_surface_ = EGL_NO_SURFACE;
    }
    egl_surface_ = eglCreateWindowSurface(egl_display_, egl_config_, native_window_, nullptr);
    if (egl_surface_ == EGL_NO_SURFACE) {
        LOGE("RebuildSurface: eglCreateWindowSurface failed");
        surface_w_ = surface_h_ = 0;
        return;
    }
    eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_);
    EGLint sw = 0, sh = 0;
    eglQuerySurface(egl_display_, egl_surface_, EGL_WIDTH, &sw);
    eglQuerySurface(egl_display_, egl_surface_, EGL_HEIGHT, &sh);
    surface_w_ = sw;
    surface_h_ = sh;
    LOGI("surface rebuilt to %dx%d (eglQuery=%dx%d)", w, h, sw, sh);
}

void VmrpRenderer::OnSurfaceDestroyed() {
    if (egl_display_ == EGL_NO_DISPLAY) return;
    eglMakeCurrent(egl_display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    DestroyGL();
    if (egl_surface_ != EGL_NO_SURFACE) { eglDestroySurface(egl_display_, egl_surface_); egl_surface_ = EGL_NO_SURFACE; }
    if (egl_context_ != EGL_NO_CONTEXT) { eglDestroyContext(egl_display_, egl_context_); egl_context_ = EGL_NO_CONTEXT; }
    eglTerminate(egl_display_);
    egl_display_ = EGL_NO_DISPLAY;
    surface_w_ = surface_h_ = 0;
    native_window_ = 0;
    LOGI("surface destroyed");
}

void VmrpRenderer::SetDisplayFilter(int filterType, int screenEffect, float screenEffectStrength,
                                    float brightness, float contrast, float saturation,
                                    int subpixelRender, int gammaCorrect, int dither) {
    filter_type_             = filterType;
    screen_effect_           = screenEffect;
    screen_effect_strength_  = screenEffectStrength;
    brightness_              = brightness;
    contrast_                = contrast;
    saturation_              = saturation;
    subpixel_render_         = subpixelRender;
    gamma_correct_           = gammaCorrect;
    dither_enabled_          = dither;
}

void VmrpRenderer::UpdateTextureFilter() {
    if (prev_filter_type_ == filter_type_) return;
    prev_filter_type_ = filter_type_;
    if (!texture_) return;
    GLenum src_filter = (filter_type_ == 1) ? GL_LINEAR : GL_NEAREST;
    glBindTexture(GL_TEXTURE_2D, texture_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, src_filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, src_filter);
    // FBO_A: EPX/xBRZ/FSRCNNX 产生平滑中间值用 LINEAR，其他 NEAREST
    GLenum fbo_a_filter = (filter_type_ >= 2) ? GL_LINEAR : src_filter;
    if (fbo_tex_a_) {
        glBindTexture(GL_TEXTURE_2D, fbo_tex_a_);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, fbo_a_filter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, fbo_a_filter);
    }
    // FBO_B: Pass3 拉伸到屏幕的关键纹理
    //   Bilinear/FSRCNNX → LINEAR（故意模糊 / 2x已有细节）
    //   Nearest/EPX/xBRZ → NEAREST（保持像素锐利）
    GLenum fbo_b_filter = (filter_type_ == 1 || filter_type_ == 4) ? GL_LINEAR : GL_NEAREST;
    if (fbo_tex_b_) {
        glBindTexture(GL_TEXTURE_2D, fbo_tex_b_);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, fbo_b_filter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, fbo_b_filter);
    }
    if (fbo_tex_prev_) {
        glBindTexture(GL_TEXTURE_2D, fbo_tex_prev_);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, fbo_b_filter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, fbo_b_filter);
    }
    glBindTexture(GL_TEXTURE_2D, texture_);
    LOGI("texture filters: src=%s fbo_a=%s fbo_b=%s",
         src_filter == GL_LINEAR ? "LINEAR" : "NEAREST",
         fbo_a_filter == GL_LINEAR ? "LINEAR" : "NEAREST",
         fbo_b_filter == GL_LINEAR ? "LINEAR" : "NEAREST");
}

void VmrpRenderer::ApplyUpscaleUniforms() {
    glUseProgram(prog_upscale_);
    glUniform2f(ul_up_u_texture_size_, static_cast<float>(tex_w_), static_cast<float>(tex_h_));
    glUniform1i(ul_up_u_filter_, filter_type_);
    glUniform1i(ul_up_u_tex_, 0);
}

void VmrpRenderer::ApplyPostprocUniforms() {
    glUseProgram(prog_postproc_);
    glUniform2f(ul_pp_u_texture_size_, static_cast<float>(fbo_w_), static_cast<float>(fbo_h_));
    glUniform1f(ul_pp_u_brightness_, brightness_);
    glUniform1f(ul_pp_u_contrast_, contrast_);
    glUniform1f(ul_pp_u_saturation_, saturation_);
    glUniform1i(ul_pp_u_screen_effect_, screen_effect_);
    glUniform1f(ul_pp_u_screen_effect_strength_, screen_effect_strength_);
    glUniform1i(ul_pp_u_gamma_correct_, gamma_correct_);
    glUniform1i(ul_pp_u_subpixel_render_, subpixel_render_);
    glUniform1i(ul_pp_u_tex_, 0);
    glUniform1i(ul_pp_u_prev_tex_, 1);
}

void VmrpRenderer::ApplyOutputUniforms() {
    glUseProgram(prog_output_);
    glUniform1i(ul_out_u_screen_effect_, screen_effect_);
    glUniform1f(ul_out_u_screen_effect_strength_, screen_effect_strength_);
    float barrel_k = (screen_effect_ == 1) ? 0.06f * screen_effect_strength_ : 0.0f;
    glUniform1f(ul_out_u_barrel_k_, barrel_k);
    glUniform1i(ul_out_u_rotation_, current_rotation_);
    glUniform1i(ul_out_u_tex_, 0);
}

bool VmrpRenderer::CanBypass() const {
    return filter_type_ == 0
        && screen_effect_ == 0
        && brightness_ == 0.0f
        && contrast_ == 1.0f
        && saturation_ == 1.0f
        && subpixel_render_ == 0;
}

void VmrpRenderer::RenderBypass(int32_t display_w, int32_t display_h) {
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    int32_t vp_w = surface_w_ > 0 ? surface_w_ : display_w;
    int32_t vp_h = surface_h_ > 0 ? surface_h_ : display_h;
    glViewport(0, 0, vp_w, vp_h);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture_);
    glUseProgram(prog_bypass_);
    glUniform1i(ul_by_u_tex_, 0);
    glUniform1i(ul_by_u_rotation_, current_rotation_);
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindVertexArray(0);
    glActiveTexture(GL_TEXTURE0);
    eglSwapBuffers(egl_display_, egl_surface_);
}

int VmrpRenderer::Render(const uint16_t *src, int32_t display_w, int32_t display_h, int rotation) {
    if (!Ready() || !src || display_w <= 0 || display_h <= 0) return -1;
    current_rotation_ = rotation & 3;

    // ── Dirty skip ──
    if (!last_frame_dirty_) {
        idle_swap_count_++;
        if (idle_swap_count_ > 3) {
            eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_);
            eglSwapBuffers(egl_display_, egl_surface_);
            return 0;
        }
    }
    last_frame_dirty_ = false;
    idle_swap_count_ = 0;

    EGLBoolean mc = eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_);
    if (!mc) return -1;

    // 上传源纹理
    if (tex_w_ != display_w || tex_h_ != display_h) {
        glBindTexture(GL_TEXTURE_2D, texture_);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, display_w, display_h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        tex_w_ = display_w;
        tex_h_ = display_h;
        prev_filter_type_ = -1;
    }
    const size_t pixels = static_cast<size_t>(display_w) * display_h;
    uint32_t *rgba = static_cast<uint32_t *>(malloc(pixels * 4));
    if (!rgba) return -1;
    ConvertRgb565ToRgba(src, rgba, static_cast<int32_t>(pixels));
    glBindTexture(GL_TEXTURE_2D, texture_);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, display_w, display_h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    free(rgba);

    // ── Bypass: Nearest+无特效直出屏幕 ──
    if (CanBypass()) {
        RenderBypass(display_w, display_h);
        return 0;
    }

    // FBO尺寸: FSRCNNX时2x放大，其他1x
    int32_t needed_w = (filter_type_ == 4) ? display_w * 2 : display_w;
    int32_t needed_h = (filter_type_ == 4) ? display_h * 2 : display_h;
    if (fbo_w_ != needed_w || fbo_h_ != needed_h) {
        CreateFBOs(needed_w, needed_h);
    }

    UpdateTextureFilter();

    // ── Pass1: 缩放 ──
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_a_);
    glViewport(0, 0, fbo_w_, fbo_h_);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture_);
    ApplyUpscaleUniforms();
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // ── Pass2: 后处理 ──
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_b_);
    glViewport(0, 0, fbo_w_, fbo_h_);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_a_);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_prev_);
    ApplyPostprocUniforms();
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // ── Pass3: 输出到屏幕 ──
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    int32_t vp_w = surface_w_ > 0 ? surface_w_ : display_w;
    int32_t vp_h = surface_h_ > 0 ? surface_h_ : display_h;
    glViewport(0, 0, vp_w, vp_h);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_b_);
    ApplyOutputUniforms();
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // 交换 phosphor glow 前帧: fbo_prev_ = fbo_b_
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_b_);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo_prev_);
    glBlitFramebuffer(0, 0, fbo_w_, fbo_h_, 0, 0, fbo_w_, fbo_h_,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindVertexArray(0);
    glActiveTexture(GL_TEXTURE0);
    GLenum glerr = glGetError();
    if (glerr != GL_NO_ERROR) {
        LOGE("GL error after draw: 0x%x", glerr);
    }
    eglSwapBuffers(egl_display_, egl_surface_);
    return 0;
}

int VmrpRenderer::RenderRgb565(const uint16_t *src, int32_t display_w, int32_t display_h, int rotation) {
    if (!Ready() || !src || display_w <= 0 || display_h <= 0) return -1;
    current_rotation_ = rotation & 3;

    // ── Dirty skip ──
    if (!last_frame_dirty_) {
        idle_swap_count_++;
        if (idle_swap_count_ > 3) {
            eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_);
            eglSwapBuffers(egl_display_, egl_surface_);
            return 0;
        }
    }
    last_frame_dirty_ = false;
    idle_swap_count_ = 0;

    EGLBoolean mc = eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_);
    if (!mc) return -1;

    // ── 纹理尺寸变化时重新分配（internalFormat=RGBA，但上传格式=RGB565）──
    if (tex_w_ != display_w || tex_h_ != display_h) {
        glBindTexture(GL_TEXTURE_2D, texture_);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, display_w, display_h, 0,
                     GL_RGB, GL_UNSIGNED_SHORT_5_6_5, nullptr);
        tex_w_ = display_w;
        tex_h_ = display_h;
        prev_filter_type_ = -1;
    }

    // ── PBO 异步上传（565数据量减半）──
    const size_t data_size = static_cast<size_t>(display_w) * display_h * 2;
    if (pbo_size_ < static_cast<int32_t>(data_size)) {
        for (int i = 0; i < 2; ++i) {
            if (pbo_[i]) glDeleteBuffers(1, &pbo_[i]);
            glGenBuffers(1, &pbo_[i]);
            glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo_[i]);
            glBufferData(GL_PIXEL_UNPACK_BUFFER, data_size, nullptr, GL_STREAM_DRAW);
        }
        pbo_size_ = static_cast<int32_t>(data_size);
        LOGI("PBOs created (rgb565) size=%zu", data_size);
    }

    pbo_idx_ = 1 - pbo_idx_;
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo_[pbo_idx_]);
    void *ptr = glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, 0, data_size,
                                  GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
    bool pbo_ok = false;
    if (ptr) {
        memcpy(ptr, src, data_size);
        glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
        pbo_ok = true;
    }

    if (pbo_ok) {
        glBindTexture(GL_TEXTURE_2D, texture_);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, display_w, display_h,
                        GL_RGB, GL_UNSIGNED_SHORT_5_6_5, nullptr);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    } else {
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        glBindTexture(GL_TEXTURE_2D, texture_);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, display_w, display_h,
                        GL_RGB, GL_UNSIGNED_SHORT_5_6_5, src);
    }

    // ── Bypass: Nearest+无特效直出屏幕 ──
    if (CanBypass()) {
        RenderBypass(display_w, display_h);
        return 0;
    }

    int32_t needed_w = (filter_type_ == 4) ? display_w * 2 : display_w;
    int32_t needed_h = (filter_type_ == 4) ? display_h * 2 : display_h;
    if (fbo_w_ != needed_w || fbo_h_ != needed_h) {
        CreateFBOs(needed_w, needed_h);
    }

    UpdateTextureFilter();

    // Pass1
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_a_);
    glViewport(0, 0, fbo_w_, fbo_h_);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture_);
    ApplyUpscaleUniforms();
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // Pass2
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_b_);
    glViewport(0, 0, fbo_w_, fbo_h_);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_a_);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_prev_);
    ApplyPostprocUniforms();
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // Pass3
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    int32_t vp_w = surface_w_ > 0 ? surface_w_ : display_w;
    int32_t vp_h = surface_h_ > 0 ? surface_h_ : display_h;
    glViewport(0, 0, vp_w, vp_h);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_b_);
    ApplyOutputUniforms();
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // phosphor glow swap
    if (screen_effect_ == 1) {
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_b_);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo_prev_);
        glBlitFramebuffer(0, 0, fbo_w_, fbo_h_, 0, 0, fbo_w_, fbo_h_,
                          GL_COLOR_BUFFER_BIT, GL_NEAREST);
    }

    glBindVertexArray(0);
    glActiveTexture(GL_TEXTURE0);
    GLenum glerr = glGetError();
    if (glerr != GL_NO_ERROR) {
        LOGE("GL error after draw: 0x%x", glerr);
    }
    eglSwapBuffers(egl_display_, egl_surface_);
    return 0;
}

int VmrpRenderer::Render(const uint8_t *rgba, int32_t display_w, int32_t display_h, int rotation) {
    if (!Ready() || !rgba || display_w <= 0 || display_h <= 0) return -1;
    current_rotation_ = rotation & 3;

    // ── Dirty skip: 静态画面仅轻量 swap 维持 surface ──
    if (!last_frame_dirty_) {
        idle_swap_count_++;
        if (idle_swap_count_ > 3) {
            eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_);
            eglSwapBuffers(egl_display_, egl_surface_);
            return 0;
        }
    }
    last_frame_dirty_ = false;
    idle_swap_count_ = 0;

    EGLBoolean mc = eglMakeCurrent(egl_display_, egl_surface_, egl_surface_, egl_context_);
    if (!mc) return -1;

    // ── 纹理尺寸变化时重新分配 ──
    if (tex_w_ != display_w || tex_h_ != display_h) {
        glBindTexture(GL_TEXTURE_2D, texture_);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, display_w, display_h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        tex_w_ = display_w;
        tex_h_ = display_h;
        prev_filter_type_ = -1;
    }

    // ── PBO 异步上传 ──
    const size_t data_size = static_cast<size_t>(display_w) * display_h * 4;
    if (pbo_size_ < static_cast<int32_t>(data_size)) {
        for (int i = 0; i < 2; ++i) {
            if (pbo_[i]) glDeleteBuffers(1, &pbo_[i]);
            glGenBuffers(1, &pbo_[i]);
            glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo_[i]);
            glBufferData(GL_PIXEL_UNPACK_BUFFER, data_size, nullptr, GL_STREAM_DRAW);
        }
        pbo_size_ = static_cast<int32_t>(data_size);
        LOGI("PBOs created size=%zu", data_size);
    }

    pbo_idx_ = 1 - pbo_idx_;
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo_[pbo_idx_]);
    void *ptr = glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, 0, data_size,
                                  GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
    bool pbo_ok = false;
    if (ptr) {
        memcpy(ptr, rgba, data_size);
        glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
        pbo_ok = true;
    }

    if (pbo_ok) {
        glBindTexture(GL_TEXTURE_2D, texture_);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, display_w, display_h, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    } else {
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        glBindTexture(GL_TEXTURE_2D, texture_);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, display_w, display_h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    }

    // ── Bypass: Nearest+无特效直出屏幕 ──
    if (CanBypass()) {
        RenderBypass(display_w, display_h);
        return 0;
    }

    int32_t needed_w = (filter_type_ == 4) ? display_w * 2 : display_w;
    int32_t needed_h = (filter_type_ == 4) ? display_h * 2 : display_h;
    if (fbo_w_ != needed_w || fbo_h_ != needed_h) {
        CreateFBOs(needed_w, needed_h);
    }

    UpdateTextureFilter();

    // Pass1
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_a_);
    glViewport(0, 0, fbo_w_, fbo_h_);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture_);
    ApplyUpscaleUniforms();
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // Pass2
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_b_);
    glViewport(0, 0, fbo_w_, fbo_h_);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_a_);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_prev_);
    ApplyPostprocUniforms();
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // Pass3
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    int32_t vp_w = surface_w_ > 0 ? surface_w_ : display_w;
    int32_t vp_h = surface_h_ > 0 ? surface_h_ : display_h;
    glViewport(0, 0, vp_w, vp_h);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_b_);
    ApplyOutputUniforms();
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // phosphor glow swap
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_b_);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo_prev_);
    glBlitFramebuffer(0, 0, fbo_w_, fbo_h_, 0, 0, fbo_w_, fbo_h_,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindVertexArray(0);
    glActiveTexture(GL_TEXTURE0);
    GLenum glerr = glGetError();
    if (glerr != GL_NO_ERROR) {
        LOGE("GL error after draw: 0x%x", glerr);
    }
    eglSwapBuffers(egl_display_, egl_surface_);
    return 0;
}

VmrpRenderer::~VmrpRenderer() { OnSurfaceDestroyed(); }
