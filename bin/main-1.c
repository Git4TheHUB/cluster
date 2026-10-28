/*
 * ============================================================================
 * Classic Happy Home (2006-2008 style) - Third Person 3D Engine
 * TI-84 Plus CE  (eZ80 @ 48 MHz, 320x240, 8bpp palette)
 * Toolchain: CE C/C++ Toolchain (CEdev) - graphx, keypadc, tice
 *
 * What's new compared to the first version
 *  - Real DDA raycaster (no per-step marching, no fisheye) with perspective-
 *    correct TEXTURED walls (32x32 textures) and a TEXTURED studded baseplate
 *    floor (row casting, fixed point).
 *  - Textures are generated procedurally at start-up: studded baseplate,
 *    red brick, concrete, wood, leaves, windowpane, yellow plate.
 *  - Lighting ramps: every material has 16 brightness levels in the palette,
 *    used for distance shading, side shading and per-face lighting.
 *  - True 3D character: real boxes (head w/ stud + face decal, torso, arms,
 *    legs) projected with the same camera, depth sorted, backface culled,
 *    black part outlines, walking swing, tool raised in the right hand
 *    like old Roblox, soft ground shadow.
 *  - Free orbit camera with wall collision (no clipping through walls).
 *  - Delta-time movement driven by a hardware timer + double buffering
 *    (gfx_SwapDraw) = smooth, tear-free.
 *  - Working tools: Classic Sword slash, Rocket Launcher (flying 3D rocket +
 *    explosion), Builder Trowel.
 *  - 2006-2008 style HUD: health bar, leaderboard, backpack hotbar.
 *
 * Controls
 *   Left / Right ..... orbit camera
 *   Up / Down ........ walk away from / toward camera
 *   Math / Apps ...... strafe left / right
 *   + / - ............ zoom camera
 *   1 / 2 / 3 ........ equip Sword / Rocket Launcher / Trowel
 *   2nd or Mode ...... use tool
 *   Clear ............ quit
 * ============================================================================
 */

#include <tice.h>
#include <graphx.h>
#include <keypadc.h>
#include <math.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

/* ------------------------------ constants -------------------------------- */
#define SW          320
#define SH          240
#define COLS        160            /* ray columns, each 2 px wide            */
#define HORIZON     104
#define PROJ        242.0f         /* (SW/2) / PLANE_LEN                      */
#define PLANE_LEN   0.66f
#define EYE_Z       38.0f          /* camera height (1 stud = 8 units)        */
#define TILE        64
#define INV_TILE    (1.0f / 64.0f)
#define MAPW        16
#define MAPH        16
#define PI_F        3.14159265f

/* materials: palette index = (material << 4) | level (0..15, 10 = base)     */
enum { M_SKY, M_GRASS, M_BRICK, M_STONE, M_WOOD, M_LEAF, M_GLASS, M_YELLOW,
       M_BLUE, M_SILVER, NUM_MATS };
#define PI_(m, l)   ((uint8_t)(((m) << 4) | (l)))

/* fixed UI colours */
#define C_BLACK   192
#define C_WHITE   193
#define C_UIDARK  194
#define C_UIGRAY  195
#define C_HP_G    196
#define C_HP_Y    197
#define C_HP_R    198
#define C_FIRE_O  199
#define C_FIRE_Y  200
#define C_TRANSP  201

static const uint8_t matRGB[NUM_MATS][3] = {
    {100, 160, 255},  /* sky                    */
    { 75, 151,  75},  /* Bright green           */
    {196,  40,  28},  /* Bright red             */
    {160, 160, 165},  /* Medium stone grey      */
    {124,  92,  70},  /* Brown                  */
    { 40, 127,  71},  /* Dark green (leaves)    */
    {160, 215, 240},  /* Glass                  */
    {245, 205,  48},  /* Bright yellow          */
    { 13, 105, 172},  /* Bright blue            */
    {205, 208, 214}   /* Silver                 */
};

/* ------------------------------- the map --------------------------------- */
static const uint8_t MAP[MAPH][MAPW] = {
    {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1},
    {1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1},
    {1,0,4,0,0,0,0,0,0,0,0,0,4,0,0,1},
    {1,0,0,0,2,2,3,2,2,0,0,0,0,0,0,1},
    {1,0,0,0,2,0,0,0,2,0,0,0,0,0,0,1},
    {1,0,0,0,3,0,0,0,3,0,0,0,0,0,0,1},
    {1,0,0,0,2,0,0,0,6,0,0,0,0,0,0,1},
    {1,0,0,0,2,2,6,2,2,0,0,0,0,0,0,1},
    {1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1},
    {1,0,5,5,0,0,0,0,0,0,5,5,0,0,0,1},
    {1,0,5,5,0,0,0,0,0,0,5,5,0,0,0,1},
    {1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1},
    {1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1},
    {1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1},
    {1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1},
    {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1}
};
static const uint8_t WALL_H[7] = {0, 80, 64, 72, 56, 64, 64};

/* tex[0] = studded baseplate, tex[1..6] = tile textures */
static uint8_t tex[7][1024];

/* ------------------------------- state ----------------------------------- */
typedef enum { TOOL_SWORD = 0, TOOL_ROCKET = 1, TOOL_TROWEL = 2 } Tool;

typedef struct {
    float x, y;            /* feet position (world units)                     */
    float facing;          /* avatar facing                                   */
    float camYaw;          /* camera orbit angle                              */
    float camMax, camDist; /* wanted / current camera distance                */
    float phase, amp;      /* walk animation                                  */
    float atkT, atkDur;    /* attack animation 1 -> 0                         */
    Tool  tool;
} Player;

static Player player = { 8.5f * TILE, 12.5f * TILE, -PI_F / 2, -PI_F / 2,
                         110.0f, 110.0f, 0, 0, 0, 0.35f, TOOL_SWORD };

typedef struct { float x, y, z, dx, dy, life; bool alive; } Rocket;
static Rocket rocket;
typedef struct { float x, y, z, t; } Boom;
static Boom boom;

static int   health = 100;
static int   gFps = 0;
static float gCamX, gCamY, gCosV, gSinV;

/* ------------------------------- helpers --------------------------------- */
static inline int RND(float v) { return (int)(v + 4096.5f) - 4096; }

static float wrapPi(float a) {
    while (a >  PI_F) a -= 2 * PI_F;
    while (a < -PI_F) a += 2 * PI_F;
    return a;
}

static inline int tileAt(float x, float y) {
    if (x < 0 || y < 0) return 1;
    int tx = (int)(x * INV_TILE), ty = (int)(y * INV_TILE);
    if (tx >= MAPW || ty >= MAPH) return 1;
    return MAP[ty][tx];
}

static bool solidBox(float x, float y, float r) {
    return tileAt(x - r, y - r) || tileAt(x + r, y - r) ||
           tileAt(x - r, y + r) || tileAt(x + r, y + r);
}

static inline uint8_t shade(uint8_t c, int d) {
    int l = (c & 15) - d;
    if (l < 0) l = 0;
    if (l > 15) l = 15;
    return (uint8_t)((c & 0xF0) | l);
}

/* project a world point to the screen; false if behind camera */
static bool project(float wx, float wy, float wz, int *sx, int *sy, float *depth) {
    float dx = wx - gCamX, dy = wy - gCamY;
    float f = dx * gCosV + dy * gSinV;
    if (f < 6.0f) return false;
    float r = -dx * gSinV + dy * gCosV;
    float k = PROJ / f;
    *sx = SW / 2 + RND(r * k);
    *sy = HORIZON - RND((wz - EYE_Z) * k);
    *depth = f;
    return true;
}

/* ------------------------- palette & textures ---------------------------- */
static void initPalette(void) {
    for (int m = 0; m < NUM_MATS; m++) {
        for (int l = 0; l < 16; l++) {
            float r = matRGB[m][0], g = matRGB[m][1], b = matRGB[m][2];
            if (l <= 10) {
                float s = 0.16f + 0.84f * (float)l / 10.0f;
                r *= s; g *= s; b *= s;
            } else {
                float t = (float)(l - 10) * 0.09f;
                r += (255 - r) * t; g += (255 - g) * t; b += (255 - b) * t;
            }
            gfx_palette[(m << 4) | l] = gfx_RGBTo1555((uint8_t)r, (uint8_t)g, (uint8_t)b);
        }
    }
    gfx_palette[C_BLACK]  = gfx_RGBTo1555(0, 0, 0);
    gfx_palette[C_WHITE]  = gfx_RGBTo1555(255, 255, 255);
    gfx_palette[C_UIDARK] = gfx_RGBTo1555(28, 28, 32);
    gfx_palette[C_UIGRAY] = gfx_RGBTo1555(120, 122, 128);
    gfx_palette[C_HP_G]   = gfx_RGBTo1555(0, 210, 0);
    gfx_palette[C_HP_Y]   = gfx_RGBTo1555(255, 220, 0);
    gfx_palette[C_HP_R]   = gfx_RGBTo1555(210, 0, 0);
    gfx_palette[C_FIRE_O] = gfx_RGBTo1555(255, 140, 0);
    gfx_palette[C_FIRE_Y] = gfx_RGBTo1555(255, 232, 80);
    gfx_palette[C_TRANSP] = gfx_RGBTo1555(255, 0, 255);
}

static uint32_t hash2(int x, int y) {
    uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}

static void buildTextures(void) {
    for (int y = 0; y < 32; y++) {
        for (int x = 0; x < 32; x++) {
            int i = (y << 5) | x;
            int l;

            /* 0: studded baseplate (4x4 studs per texture) */
            {
                int cx = x & 7, cy = y & 7;
                int dx = 2 * cx - 7, dy = 2 * cy - 7;
                int d2 = dx * dx + dy * dy, s = dx + dy;
                if (d2 <= 34) {
                    if (s > 3) l = 10; else if (s > 0) l = 11;
                    else if (s < -3) l = 14; else l = 13;
                } else if (d2 <= 62 && s > 0) l = 6;
                else l = 9;
                tex[0][i] = PI_(M_GRASS, l);
            }

            /* 1: concrete border wall */
            l = 10 + (int)(hash2(x, y) & 1);
            if ((x & 15) == 0 || (y & 15) == 0) l = 6;
            else if ((x & 15) == 1 || (y & 15) == 1) l = 12;
            tex[1][i] = PI_(M_STONE, l);

            /* 2: red brick */
            {
                int row = y >> 3, off = (row & 1) ? 8 : 0;
                int bx = (x + off) & 15, by = y & 7;
                if (by == 0 || bx == 0) tex[2][i] = PI_(M_STONE, 8);
                else {
                    l = 9 + (int)(hash2((x + off) >> 4, row) & 3);
                    if (by == 1) l += 2;
                    if (by == 7) l -= 2;
                    tex[2][i] = PI_(M_BRICK, l);
                }
            }

            /* 3: yellow plastic plate */
            l = 10;
            if ((y & 15) == 0) l = 6; else if ((y & 15) == 1) l = 13;
            if ((x & 15) == 0) l = 8;
            tex[3][i] = PI_(M_YELLOW, l);

            /* 4: wood bark */
            l = 7 + (int)(hash2(x >> 1, 0) & 3) + (int)(hash2(x >> 2, y >> 2) & 1);
            if ((x & 7) == 0) l = 4;
            tex[4][i] = PI_(M_WOOD, l);

            /* 5: leaves */
            l = 6 + (int)(hash2(x >> 1, y >> 1) & 3) + (((x + y) & 1) ? 0 : 1);
            tex[5][i] = PI_(M_LEAF, l);

            /* 6: window pane with wooden frame */
            if (x < 3 || x > 28 || y < 3 || y > 28 || x == 15 || x == 16 || y == 15 || y == 16)
                tex[6][i] = PI_(M_WOOD, 8);
            else if (x == 3 || x == 28 || y == 3 || y == 28)
                tex[6][i] = PI_(M_WOOD, 4);
            else {
                l = 11;
                if (((x + y) & 15) < 3) l = 14;
                tex[6][i] = PI_(M_GLASS, l);
            }
        }
    }
}

/* ------------------------------ sky & floor ------------------------------ */
static void drawSky(void) {
    uint8_t *buf = (uint8_t *)gfx_vbuffer;
    for (int y = 0; y < HORIZON; y++)
        memset(buf + y * SW, PI_(M_SKY, 7 + (6 * y) / HORIZON), SW);

    /* parallax clouds */
    static const int8_t cl[4][3] = {{20, 28, 50}, {150, 18, 60}, {250, 45, 44}, {90, 62, 38}};
    int off = -(int)(player.camYaw * 70.0f);
    gfx_SetColor(C_WHITE);
    for (int i = 0; i < 4; i++) {
        int w = cl[i][2];
        int x = (((cl[i][0] + 100 * (i & 1) + off) % 480) + 480) % 480 - 80;
        int y = cl[i][1];
        gfx_FillEllipse(x, y, w / 2, w / 7 + 2);
        gfx_FillEllipse(x - w / 3, y + 3, w / 3, w / 8 + 1);
        gfx_FillEllipse(x + w / 3, y + 3, w / 3, w / 8 + 1);
    }
}

static void drawFloor(void) {
    uint8_t *buf = (uint8_t *)gfx_vbuffer;
    float rX = -gSinV, rY = gCosV;
    const uint8_t *ft = tex[0];

    for (int y = HORIZON; y < SH; y += 2) {
        float f = EYE_Z * PROJ / (float)(y - HORIZON + 1);
        if (f > 2400.0f) f = 2400.0f;
        int d = (int)f >> 7;
        float lat = f / PROJ;
        float fx0 = gCamX + gCosV * f + rX * (-159.0f) * lat;
        float fy0 = gCamY + gSinV * f + rY * (-159.0f) * lat;
        int fx = (int)(fx0 * 256.0f), fy = (int)(fy0 * 256.0f);
        int sx = (int)(rX * 2.0f * lat * 256.0f);
        int sy = (int)(rY * 2.0f * lat * 256.0f);

        uint8_t *p0 = buf + y * SW;
        uint8_t *p1 = p0 + SW;
        for (int i = 0; i < COLS; i++) {
            uint8_t c = ft[(((fy >> 8) & 31) << 5) | ((fx >> 8) & 31)];
            int l = (c & 15) - d;
            if (l < 0) l = 0;
            c = (uint8_t)((c & 0xF0) | l);
            p0[0] = p0[1] = p1[0] = p1[1] = c;
            p0 += 2; p1 += 2;
            fx += sx; fy += sy;
        }
    }
}

/* -------------------------------- walls ---------------------------------- */
static void drawWalls(void) {
    uint8_t *buf = (uint8_t *)gfx_vbuffer;
    float dirX = gCosV, dirY = gSinV;
    float plX = -gSinV * PLANE_LEN, plY = gCosV * PLANE_LEN;
    float posX = gCamX * INV_TILE, posY = gCamY * INV_TILE;
    int mapX0 = (int)posX, mapY0 = (int)posY;

    for (int i = 0; i < COLS; i++) {
        float cx = (float)(2 * i + 1 - COLS) / (float)COLS;
        float rdx = dirX + plX * cx, rdy = dirY + plY * cx;
        int mapX = mapX0, mapY = mapY0;
        float ddx = (rdx == 0.0f) ? 1e30f : fabsf(1.0f / rdx);
        float ddy = (rdy == 0.0f) ? 1e30f : fabsf(1.0f / rdy);
        int stepX, stepY;
        float sdx, sdy;
        if (rdx < 0) { stepX = -1; sdx = (posX - (float)mapX) * ddx; }
        else         { stepX =  1; sdx = ((float)mapX + 1.0f - posX) * ddx; }
        if (rdy < 0) { stepY = -1; sdy = (posY - (float)mapY) * ddy; }
        else         { stepY =  1; sdy = ((float)mapY + 1.0f - posY) * ddy; }

        int side = 0, tile = 1;
        for (int n = 0; n < 48; n++) {
            if (sdx < sdy) { sdx += ddx; mapX += stepX; side = 0; }
            else           { sdy += ddy; mapY += stepY; side = 1; }
            if (mapX < 0 || mapY < 0 || mapX >= MAPW || mapY >= MAPH) { tile = 1; break; }
            uint8_t t = MAP[mapY][mapX];
            if (t) { tile = t; break; }
        }

        float perp = side ? (sdy - ddy) : (sdx - ddx);
        float dist = perp * TILE;
        if (dist < 3.0f) dist = 3.0f;

        float wallX = side ? (posX + perp * rdx) : (posY + perp * rdy);
        wallX -= floorf(wallX);
        int texX = (int)(wallX * 32.0f);
        if (texX > 31) texX = 31;
        if ((side == 0 && rdx > 0) || (side == 1 && rdy < 0)) texX = 31 - texX;

        float k = PROJ / dist;
        int top = HORIZON - (int)(((float)WALL_H[tile] - EYE_Z) * k);
        int bot = HORIZON + (int)(EYE_Z * k);
        int total = bot - top;
        if (total < 1) total = 1;
        int step = (32 << 8) / total;
        int y0 = top < 0 ? 0 : top;
        int y1 = bot > SH ? SH : bot;
        int tp = (y0 - top) * step;
        int d = ((int)dist >> 7) + (side ? 2 : 0);

        const uint8_t *col = &tex[tile][texX];
        uint8_t *p = buf + y0 * SW + i * 2;
        for (int y = y0; y < y1; y++) {
            uint8_t c = col[((tp >> 8) & 31) << 5];
            int l = (c & 15) - d;
            if (l < 0) l = 0;
            c = (uint8_t)((c & 0xF0) | l);
            p[0] = p[1] = c;
            p += SW;
            tp += step;
        }
    }
}

/* soft blob shadow: darkens whatever is under the avatar */
static void drawShadow(void) {
    int sx, sy; float f;
    if (!project(player.x, player.y, 0.0f, &sx, &sy, &f)) return;
    float k = PROJ / f;
    int rx = (int)(10.0f * k);
    if (rx > 40) rx = 40;
    if (rx < 2) rx = 2;
    int ry = (int)((float)rx * EYE_Z / f);
    if (ry > 16) ry = 16;
    if (ry < 1) ry = 1;
    uint8_t *buf = (uint8_t *)gfx_vbuffer;
    for (int dy = -ry; dy <= ry; dy++) {
        int y = sy + dy;
        if (y < 0 || y >= SH) continue;
        for (int dx = -rx; dx <= rx; dx++) {
            int x = sx + dx;
            if (x < 0 || x >= SW) continue;
            if (dx * dx * ry * ry + dy * dy * rx * rx <= rx * rx * ry * ry) {
                uint8_t *p = buf + y * SW + x;
                if (*p < 0xC0) *p = shade(*p, 4);
            }
        }
    }
}

/* --------------------------- 3D box part renderer ------------------------- */
typedef struct { float ox, oy, fx, fy, rx, ry; } Frame;
static Frame fr;

typedef struct {
    float pr, pf, pz;     /* pivot in frame coords (right, forward, up)      */
    float cr, cf, cz;     /* box centre relative to pivot (before swing)     */
    float hr, hf, hz;     /* half sizes                                       */
    float cs, sn;         /* swing about the right axis                       */
    float depth;
    uint8_t mat;
    bool face;
} Part;

static Part parts[28];
static int nParts = 0;

static const uint8_t FACE_V[5][4] = {{4,5,7,6},{2,3,7,6},{0,1,5,4},{1,3,7,5},{0,2,6,4}};
static const int8_t  FACE_N[5][3] = {{0,0,1},{0,1,0},{0,-1,0},{1,0,0},{-1,0,0}};
#define LX 0.40f
#define LY 0.30f
#define LZ 0.866f

static void addPart(float pr, float pf, float pz,
                    float cr, float cf, float cz,
                    float hr, float hf, float hz,
                    float swing, uint8_t mat, bool face, float bias) {
    if (nParts >= 28) return;
    Part *p = &parts[nParts++];
    p->pr = pr; p->pf = pf; p->pz = pz;
    p->cr = cr; p->cf = cf; p->cz = cz;
    p->hr = hr; p->hf = hf; p->hz = hz;
    p->cs = cosf(swing); p->sn = sinf(swing);
    p->mat = mat; p->face = face;
    float f2 = cf * p->cs - cz * p->sn + pf;
    float r  = pr + cr;
    float wx = fr.ox + fr.rx * r + fr.fx * f2;
    float wy = fr.oy + fr.ry * r + fr.fy * f2;
    p->depth = (wx - gCamX) * gCosV + (wy - gCamY) * gSinV - bias;
}

static void facePt(const float *wx, const float *wy, const float *wz,
                   float u, float v, int *sx, int *sy) {
    float bx = wx[2] + (wx[3] - wx[2]) * u, tx = wx[6] + (wx[7] - wx[6]) * u;
    float by = wy[2] + (wy[3] - wy[2]) * u, ty = wy[6] + (wy[7] - wy[6]) * u;
    float bz = wz[2] + (wz[3] - wz[2]) * u, tz = wz[6] + (wz[7] - wz[6]) * u;
    float d;
    if (!project(bx + (tx - bx) * v, by + (ty - by) * v, bz + (tz - bz) * v, sx, sy, &d)) {
        *sx = -999; *sy = -999;
    }
}

static void faceQuad(const float *wx, const float *wy, const float *wz,
                     float u0, float v0, float u1, float v1) {
    int ax, ay, bx, by, cx, cy, dx, dy;
    facePt(wx, wy, wz, u0, v0, &ax, &ay);
    facePt(wx, wy, wz, u1, v0, &bx, &by);
    facePt(wx, wy, wz, u1, v1, &cx, &cy);
    facePt(wx, wy, wz, u0, v1, &dx, &dy);
    gfx_FillTriangle(ax, ay, bx, by, cx, cy);
    gfx_FillTriangle(ax, ay, cx, cy, dx, dy);
}

/* classic Roblox smile: two eyes + curved mouth */
static void drawFaceDecal(const float *wx, const float *wy, const float *wz) {
    gfx_SetColor(C_BLACK);
    faceQuad(wx, wy, wz, 0.27f, 0.50f, 0.37f, 0.78f);
    faceQuad(wx, wy, wz, 0.63f, 0.50f, 0.73f, 0.78f);
    int px = 0, py = 0, qx, qy;
    for (int s = 0; s <= 6; s++) {
        float u = 0.22f + 0.56f * (float)s / 6.0f;
        float t = (u - 0.5f) / 0.28f;
        float v = 0.16f + 0.24f * t * t;
        facePt(wx, wy, wz, u, v, &qx, &qy);
        if (s > 0) {
            gfx_Line(px, py, qx, qy);
            gfx_Line(px, py + 1, qx, qy + 1);
        }
        px = qx; py = qy;
    }
}

static void drawPart(const Part *p) {
    float wx[8], wy[8], wz[8];
    int sx[8], sy[8];
    float dep;
    for (int i = 0; i < 8; i++) {
        float r = p->cr + ((i & 1) ? p->hr : -p->hr);
        float f = p->cf + ((i & 2) ? p->hf : -p->hf);
        float z = p->cz + ((i & 4) ? p->hz : -p->hz);
        float f2 = f * p->cs - z * p->sn + p->pf;
        float z2 = f * p->sn + z * p->cs + p->pz;
        r += p->pr;
        wx[i] = fr.ox + fr.rx * r + fr.fx * f2;
        wy[i] = fr.oy + fr.ry * r + fr.fy * f2;
        wz[i] = z2;
        if (!project(wx[i], wy[i], wz[i], &sx[i], &sy[i], &dep)) return;
    }
    for (int fc = 0; fc < 5; fc++) {
        const uint8_t *v = FACE_V[fc];
        float nr = FACE_N[fc][0], nf = FACE_N[fc][1], nz = FACE_N[fc][2];
        float nf2 = nf * p->cs - nz * p->sn;
        float nz2 = nf * p->sn + nz * p->cs;
        float nwx = fr.rx * nr + fr.fx * nf2;
        float nwy = fr.ry * nr + fr.fy * nf2;
        float cx = (wx[v[0]] + wx[v[2]]) * 0.5f;
        float cy = (wy[v[0]] + wy[v[2]]) * 0.5f;
        float cz = (wz[v[0]] + wz[v[2]]) * 0.5f;
        if (nwx * (gCamX - cx) + nwy * (gCamY - cy) + nz2 * (EYE_Z - cz) <= 0.0f) continue;

        float dl = nwx * LX + nwy * LY + nz2 * LZ;
        if (dl < 0) dl = 0;
        gfx_SetColor(PI_(p->mat, 6 + (int)(8.0f * dl)));
        gfx_FillTriangle(sx[v[0]], sy[v[0]], sx[v[1]], sy[v[1]], sx[v[2]], sy[v[2]]);
        gfx_FillTriangle(sx[v[0]], sy[v[0]], sx[v[2]], sy[v[2]], sx[v[3]], sy[v[3]]);

        gfx_SetColor(C_BLACK);   /* old-school part outline */
        gfx_Line(sx[v[0]], sy[v[0]], sx[v[1]], sy[v[1]]);
        gfx_Line(sx[v[1]], sy[v[1]], sx[v[2]], sy[v[2]]);
        gfx_Line(sx[v[2]], sy[v[2]], sx[v[3]], sy[v[3]]);
        gfx_Line(sx[v[3]], sy[v[3]], sx[v[0]], sy[v[0]]);

        if (fc == 1 && p->face) drawFaceDecal(wx, wy, wz);
    }
}

static void flushParts(void) {
    for (int i = 1; i < nParts; i++) {          /* far -> near */
        Part t = parts[i];
        int j = i - 1;
        while (j >= 0 && parts[j].depth < t.depth) { parts[j + 1] = parts[j]; j--; }
        parts[j + 1] = t;
    }
    for (int i = 0; i < nParts; i++) drawPart(&parts[i]);
    nParts = 0;
}

/* ------------------------------ the avatar ------------------------------- */
static void drawCharacter(void) {
    fr.ox = player.x; fr.oy = player.y;
    fr.fx = cosf(player.facing); fr.fy = sinf(player.facing);
    fr.rx = -fr.fy;              fr.ry = fr.fx;
    nParts = 0;

    float s = sinf(player.phase) * player.amp * 0.85f;
    float armR = s;
    bool holding = true;                    /* a tool is always equipped */
    if (holding) {
        float t = player.atkT;
        armR = 1.40f;
        if (player.tool == TOOL_SWORD)  armR += 1.3f * t;
        if (player.tool == TOOL_ROCKET) armR += 0.35f * t;
        if (player.tool == TOOL_TROWEL) armR += 0.7f * sinf(t * PI_F);
    }

    /* legs: Bright green */
    addPart(-4, 0, 16,  0, 0, -8,  3.9f, 3.9f, 8,  s, M_GRASS, false, 0);
    addPart( 4, 0, 16,  0, 0, -8,  3.9f, 3.9f, 8, -s, M_GRASS, false, 0);
    /* torso: Bright blue + studs */
    addPart(0, 0, 0,  0, 0, 24,  8, 4, 8, 0, M_BLUE, false, 0);
    addPart(0, 0, 0, -4, 0, 32.9f,  2, 2, 1, 0, M_BLUE, false, 1);
    addPart(0, 0, 0,  4, 0, 32.9f,  2, 2, 1, 0, M_BLUE, false, 1);
    /* head: yellow with smile + stud */
    addPart(0, 0, 0,  0, 0, 36,  4.4f, 4.4f, 4, 0, M_YELLOW, true, 0);
    addPart(0, 0, 0,  0, 0, 40.9f,  2, 2, 1, 0, M_YELLOW, false, 1);
    /* left arm */
    addPart(-12, 0, 32,  0, 0, -8,  3.9f, 3.9f, 8, -s, M_YELLOW, false, 0);
    /* right arm (holds tool) */
    addPart( 12, 0, 32,  0, 0, -8,  3.9f, 3.9f, 8, armR, M_YELLOW, false, 0);

    /* tool, rigidly attached to the right arm pivot */
    switch (player.tool) {
        case TOOL_SWORD:
            addPart(12, 0, 32,  0, 0.0f, -16,  1.2f, 3.0f, 1.2f, armR, M_WOOD,   false, -2);
            addPart(12, 0, 32,  0, 3.6f, -16,  4.0f, 0.8f, 1.3f, armR, M_YELLOW, false, -2);
            addPart(12, 0, 32,  0, 13.4f, -16, 1.6f, 9.0f, 0.7f, armR, M_SILVER, false, -2);
            break;
        case TOOL_ROCKET:
            addPart(12, 0, 32,  0, 2, -20,  3.0f, 3.0f, 11, armR, M_BRICK, false, -2);
            addPart(12, 0, 32,  0, 2, -31.5f, 3.5f, 3.5f, 1, armR, M_STONE, false, -2);
            addPart(12, 0, 32,  0, -2.5f, -17, 1.2f, 1.8f, 2.5f, armR, M_WOOD, false, -2);
            break;
        default:
            addPart(12, 0, 32,  0, 0, -16,  1.2f, 1.2f, 3, armR, M_WOOD, false, -2);
            addPart(12, 0, 32,  0, 0, -24.5f, 3.0f, 0.7f, 5.5f, armR, M_SILVER, false, -2);
            break;
    }
    flushParts();
}

/* ------------------------- rocket & explosion ---------------------------- */
static void drawProjectiles(void) {
    if (rocket.alive) {
        float a = atan2f(rocket.dy, rocket.dx);
        fr.ox = rocket.x; fr.oy = rocket.y;
        fr.fx = cosf(a);  fr.fy = sinf(a);
        fr.rx = -fr.fy;   fr.ry = fr.fx;
        nParts = 0;
        addPart(0, 0, rocket.z,  0, 0, 0,  2.2f, 7, 2.2f, 0, M_BRICK, false, 0);
        addPart(0, 0, rocket.z,  0, 8.5f, 0,  1.6f, 1.6f, 1.6f, 0, M_STONE, false, -1);
        flushParts();
    }
    if (boom.t > 0) {
        int sx, sy; float f;
        if (project(boom.x, boom.y, boom.z, &sx, &sy, &f)) {
            float p = 1.0f - boom.t / 0.45f;
            int r = (int)((14.0f + 34.0f * p) * PROJ / f);
            if (r > 110) r = 110;
            gfx_SetColor(C_FIRE_O); gfx_FillCircle(sx, sy, r);
            gfx_SetColor(C_FIRE_Y); gfx_FillCircle(sx, sy, (r * 2) / 3);
            gfx_SetColor(C_WHITE);  gfx_FillCircle(sx, sy, r / 3);
        }
    }
}

/* --------------------------------- HUD ----------------------------------- */
static void drawToolIcon(int i, int bx, int by) {
    if (i == 0) {                                  /* sword */
        gfx_SetColor(PI_(M_SILVER, 13));
        gfx_Line(bx + 12, by + 22, bx + 26, by + 6);
        gfx_Line(bx + 13, by + 22, bx + 27, by + 6);
        gfx_SetColor(PI_(M_YELLOW, 10));
        gfx_Line(bx + 9, by + 19, bx + 15, by + 25);
        gfx_SetColor(PI_(M_WOOD, 9));
        gfx_Line(bx + 8, by + 26, bx + 12, by + 22);
    } else if (i == 1) {                           /* rocket launcher */
        gfx_SetColor(PI_(M_BRICK, 10));
        gfx_FillRectangle(bx + 6, by + 14, 26, 8);
        gfx_SetColor(PI_(M_STONE, 11));
        gfx_FillRectangle(bx + 30, by + 13, 3, 10);
        gfx_SetColor(PI_(M_WOOD, 9));
        gfx_FillRectangle(bx + 12, by + 22, 4, 6);
    } else {                                       /* trowel */
        gfx_SetColor(PI_(M_SILVER, 12));
        gfx_FillTriangle(bx + 20, by + 5, bx + 12, by + 19, bx + 28, by + 19);
        gfx_SetColor(PI_(M_WOOD, 9));
        gfx_FillRectangle(bx + 18, by + 19, 4, 9);
    }
}

static void drawHUD(void) {
    /* health bar (top right) */
    gfx_SetTextFGColor(C_WHITE);
    gfx_PrintStringXY("Health", 270, 4);
    gfx_SetColor(C_BLACK);
    gfx_FillRectangle(212, 14, 102, 12);
    gfx_SetColor(C_WHITE);
    gfx_Rectangle(212, 14, 102, 12);
    gfx_SetColor(health > 60 ? C_HP_G : (health > 30 ? C_HP_Y : C_HP_R));
    gfx_FillRectangle(213, 15, health, 10);

    /* leaderboard */
    gfx_SetColor(C_UIDARK);
    gfx_FillRectangle(232, 32, 82, 30);
    gfx_SetColor(C_UIGRAY);
    gfx_Rectangle(232, 32, 82, 30);
    gfx_SetTextFGColor(C_WHITE);
    gfx_PrintStringXY("Player", 237, 36);
    gfx_PrintStringXY("Points 0", 237, 48);

    /* place / tool / fps (top left) */
    gfx_SetColor(C_UIDARK);
    gfx_FillRectangle(4, 4, 150, 30);
    gfx_SetColor(C_UIGRAY);
    gfx_Rectangle(4, 4, 150, 30);
    gfx_PrintStringXY("Happy Home", 9, 8);
    gfx_PrintStringXY(player.tool == TOOL_SWORD ? "Classic Sword" :
                      player.tool == TOOL_ROCKET ? "Rocket Launcher" : "Builder Trowel", 9, 20);
    gfx_SetTextXY(120, 8);
    gfx_PrintInt(gFps, 2);

    /* backpack hotbar */
    static const char *num[3] = {"1", "2", "3"};
    for (int i = 0; i < 3; i++) {
        int bx = 99 + i * 42, by = 202;
        gfx_SetColor(C_UIDARK);
        gfx_FillRectangle(bx, by, 38, 34);
        gfx_SetColor(i == (int)player.tool ? C_HP_Y : C_WHITE);
        gfx_Rectangle(bx, by, 38, 34);
        if (i == (int)player.tool) gfx_Rectangle(bx + 1, by + 1, 36, 32);
        drawToolIcon(i, bx, by + 2);
        gfx_SetTextFGColor(C_WHITE);
        gfx_PrintStringXY(num[i], bx + 3, by + 3);
    }
}

/* ------------------------------ game update ------------------------------ */
static void update(float dt) {
    float turn = 0;
    if (kb_IsDown(kb_KeyLeft))  turn -= 1;
    if (kb_IsDown(kb_KeyRight)) turn += 1;
    player.camYaw = wrapPi(player.camYaw + turn * 2.4f * dt);

    if (kb_IsDown(kb_KeyAdd)) { player.camMax += 80.0f * dt; if (player.camMax > 190) player.camMax = 190; }
    if (kb_IsDown(kb_KeySub)) { player.camMax -= 80.0f * dt; if (player.camMax < 60)  player.camMax = 60; }

    if (kb_IsDown(kb_Key1)) { player.tool = TOOL_SWORD;  player.atkDur = 0.35f; }
    if (kb_IsDown(kb_Key2)) { player.tool = TOOL_ROCKET; player.atkDur = 0.70f; }
    if (kb_IsDown(kb_Key3)) { player.tool = TOOL_TROWEL; player.atkDur = 0.30f; }

    float cv = cosf(player.camYaw), sv = sinf(player.camYaw);
    float fwd = 0, str = 0;
    if (kb_IsDown(kb_KeyUp))   fwd += 1;
    if (kb_IsDown(kb_KeyDown)) fwd -= 1;
    if (kb_IsDown(kb_KeyApps)) str += 1;
    if (kb_IsDown(kb_KeyMath)) str -= 1;

    float mx = cv * fwd - sv * str;
    float my = sv * fwd + cv * str;
    float len = sqrtf(mx * mx + my * my);
    bool moving = len > 0.01f;
    if (moving) {
        mx /= len; my /= len;
        float spd = 80.0f * dt;
        float nx = player.x + mx * spd;
        if (!solidBox(nx, player.y, 6.0f)) player.x = nx;
        float ny = player.y + my * spd;
        if (!solidBox(player.x, ny, 6.0f)) player.y = ny;

        float diff = wrapPi(atan2f(my, mx) - player.facing);
        float maxStep = 14.0f * dt;
        if (diff > maxStep) diff = maxStep;
        if (diff < -maxStep) diff = -maxStep;
        player.facing = wrapPi(player.facing + diff);
        player.phase += 10.0f * dt;
    }
    float target = moving ? 1.0f : 0.0f;
    float a = 10.0f * dt; if (a > 1) a = 1;
    player.amp += (target - player.amp) * a;
    if (!moving && player.amp < 0.02f) player.phase = 0;

    /* use tool */
    if ((kb_IsDown(kb_Key2nd) || kb_IsDown(kb_KeyMode)) && player.atkT <= 0) {
        player.atkT = 1.0f;
        player.facing = player.camYaw;               /* aim where camera looks */
        if (player.tool == TOOL_ROCKET && !rocket.alive) {
            rocket.alive = true;
            rocket.dx = cv; rocket.dy = sv;
            rocket.x = player.x + cv * 16; rocket.y = player.y + sv * 16;
            rocket.z = 27; rocket.life = 3.0f;
        }
    }
    if (player.atkT > 0) {
        player.atkT -= dt / player.atkDur;
        if (player.atkT < 0) player.atkT = 0;
    }

    if (rocket.alive) {
        rocket.x += rocket.dx * 320.0f * dt;
        rocket.y += rocket.dy * 320.0f * dt;
        rocket.life -= dt;
        if (tileAt(rocket.x, rocket.y) || rocket.life <= 0) {
            rocket.alive = false;
            boom.x = rocket.x; boom.y = rocket.y; boom.z = rocket.z; boom.t = 0.45f;
        }
    }
    if (boom.t > 0) boom.t -= dt;

    /* camera boom with wall avoidance */
    float d;
    for (d = 8.0f; d < player.camMax; d += 4.0f) {
        float px = player.x - cv * d, py = player.y - sv * d;
        if (solidBox(px, py, 6.0f)) break;
    }
    float want = (d < player.camMax) ? d - 4.0f : player.camMax;
    if (want < 16.0f) want = 16.0f;
    if (want < player.camDist) player.camDist = want;
    else {
        float k = 6.0f * dt; if (k > 1) k = 1;
        player.camDist += (want - player.camDist) * k;
    }
}

static void render(void) {
    gCosV = cosf(player.camYaw);
    gSinV = sinf(player.camYaw);
    gCamX = player.x - gCosV * player.camDist;
    gCamY = player.y - gSinV * player.camDist;

    drawSky();
    drawFloor();
    drawWalls();
    drawShadow();
    drawCharacter();
    drawProjectiles();
    drawHUD();
}

/* --------------------------------- main ---------------------------------- */
int main(void) {
    gfx_Begin();
    gfx_SetDrawBuffer();
    initPalette();
    buildTextures();
    gfx_SetTextTransparentColor(C_TRANSP);
    gfx_SetTextBGColor(C_TRANSP);
    gfx_SetTextScale(1, 1);

    timer_Set(1, 0);
    timer_Enable(1, TIMER_32K, TIMER_NOINT, TIMER_UP);

    float fpsAcc = 0; int fpsN = 0;
    while (!kb_IsDown(kb_KeyClear)) {
        kb_Scan();
        uint32_t ticks = timer_Get(1);
        timer_Set(1, 0);
        float dt = (float)ticks / 32768.0f;
        if (dt > 0.05f) dt = 0.05f;
        if (dt < 0.001f) dt = 0.001f;

        fpsAcc += dt; fpsN++;
        if (fpsAcc >= 0.5f) { gFps = (int)((float)fpsN / fpsAcc + 0.5f); fpsAcc = 0; fpsN = 0; }

        update(dt);
        render();
        gfx_SwapDraw();
    }
    gfx_End();
    return 0;
}
