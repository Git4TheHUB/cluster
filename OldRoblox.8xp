/*
 * ============================================================================
 * Classic Roblox-Style Happy Home  (v2)
 * TI-84 Plus CE / CEdev
 *
 * main.c
 *
 * Controls
 *   Arrows        Up/Down = walk, Left/Right = turn camera
 *   Apps / Math   Strafe right / left
 *   Alpha         Jump
 *   2nd / Mode    Use tool (Grab = hold)
 *   1 2 3 4       Clone, Grab, Delete, Rocket
 *   + / -         Camera zoom (zoom all the way in = first person)
 *   Del           Reset character
 *   Clear         Quit
 *
 * Notes for CEdev: 'int' is 24-bit, 'long' is 32-bit, float is software
 * emulated (slow).  The per-ray and per-pixel loops below are therefore
 * integer / fixed-point; floats are used only for per-object work.
 * ============================================================================
 */

#include <tice.h>
#include <graphx.h>
#include <keypadc.h>

#include <stdint.h>
#include <stdbool.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>

/* =========================================================================
 * CONFIGURATION
 * ========================================================================= */

#define SW                  320
#define SH                  240

#define HORIZON             104
#define RAY_COUNT           160

#define MAP_W               24
#define MAP_H               24

#define TILE_SIZE           64.0f
#define INV_TILE_SIZE       (1.0f / TILE_SIZE)

/* Roblox scale: 1 stud = 8 world units. */
#define STUD                8.0f

/*
 * Projection. 120 px half-height / tan(35 deg) gives Roblox's default
 * 70 degree vertical field of view on a 320x240 screen.
 * FOV_PLANE is derived from the SAME projection so walls, floor and
 * objects all agree horizontally (the old file used 0.66 for walls and
 * 0.89 for everything else, which made walls and props drift apart).
 */
#define PROJECTION          171.0f
#define PROJECTION_I        171
#define FOV_PLANE           ((SW / 2.0f) / PROJECTION)

#define EYE_HEIGHT          38.0f
#define WALL_HEIGHT         64
#define WALL_NUM            (PROJECTION_I * 4)   /* distance is in 1/4 units */

#define TRIG_SIZE           512
#define TRIG_MASK           (TRIG_SIZE - 1)

#define TEX_SIZE            32
#define TEX_PIXELS          (TEX_SIZE * TEX_SIZE)

#define MAX_WORLD_PARTS     96
#define MAX_DRAW_ITEMS      128
#define MAX_DEBRIS          7

#define MAX_DRAW_DISTANCE   1900.0f

/* ---- Roblox physics (classic defaults, converted to units) ---- */
#define WALK_SPEED          (16.0f * STUD)       /* 16 studs/s            */
#define JUMP_VELOCITY       (50.0f * STUD)       /* JumpPower 50          */
#define GRAVITY             (196.2f * STUD)      /* workspace gravity     */
#define MAX_HEALTH          100.0f
#define HEALTH_REGEN        1.0f                 /* 1% of max per second  */
#define RESPAWN_TIME        3.0f
#define PLAYER_RADIUS       7.0f
#define BODY_HEIGHT         40.0f                /* 5 studs tall          */
#define STEP_HEIGHT         6.0f

#define ROCKET_SPEED        (60.0f * STUD)
#define EXPLOSION_RADIUS    (4.0f * STUD)        /* default BlastRadius   */
#define EXPLOSION_DAMAGE    100.0f               /* breaks joints = death */
#define EXPLOSION_TIME      0.45f

#define BUILD_GRID          STUD                 /* snap to 1 stud        */
#define BUILD_DISTANCE      160.0f

#define FIRST_PERSON_DIST   10.0f

#define FOG_START           900.0f
#define FOG_END             1800.0f

#define SPAWN_X             (13.5f * TILE_SIZE)
#define SPAWN_Y             (18.75f * TILE_SIZE)

#define SUN_ANGLE           (-0.85f)

#define PI_F                3.14159265358979323846f

/* =========================================================================
 * MATERIALS / PALETTE
 * ========================================================================= */

enum {
    MAT_SKY = 0,
    MAT_GRASS,
    MAT_BRICK,
    MAT_STONE,
    MAT_WOOD,
    MAT_LEAF,
    MAT_GLASS,
    MAT_YELLOW,
    MAT_BLUE,
    MAT_SILVER,
    MAT_TAN,
    MAT_RED,
    MAT_WHITE,
    MAT_COUNT
};

/* Palette index = material * 16 + brightness.  13 * 16 = 208 entries. */

#define PIXEL(material, light) \
    ((uint8_t)(((material) << 4) | ((light) & 15)))

#define UI_BLACK       224
#define UI_WHITE       225
#define UI_DARK        226
#define UI_GRAY        227
#define UI_GREEN       228
#define UI_YELLOW      229
#define UI_RED         230
#define UI_ORANGE      231
#define UI_FIRE        232
#define UI_SELECT      233
#define UI_CLOUD       234
#define UI_CLOUDSHADE  235
#define UI_SUNGLOW     236

static const uint8_t materialRGB[MAT_COUNT][3] = {
    {110, 180, 255}, /* Sky */
    { 75, 151,  75}, /* Bright green (classic baseplate) */
    {196,  40,  28}, /* Bright red (brick) */
    {160, 160, 165}, /* Medium stone grey */
    {124,  92,  70}, /* Reddish brown (wood) */
    { 40, 127,  71}, /* Dark green (leaves) */
    {160, 215, 240}, /* Glass */
    {245, 205,  48}, /* Bright yellow */
    { 13, 105, 172}, /* Bright blue */
    {205, 208, 214}, /* Silver */
    {210, 180, 140}, /* Tan */
    {180,  35,  25}, /* Red */
    {240, 240, 240}  /* White */
};

/* =========================================================================
 * MAP
 * ========================================================================= */

enum {
    TILE_EMPTY = 0,
    TILE_BRICK = 1,
    TILE_TAN = 2,
    TILE_GLASS = 3,
    TILE_WOOD = 4,
    TILE_LEAVES = 5,
    TILE_STONE = 6
};

enum {
    TEX_BASEPLATE = 0,
    TEX_STONE,
    TEX_BRICK,
    TEX_PLASTER,
    TEX_WOOD,
    TEX_LEAVES,
    TEX_GLASS,
    TEX_PATH,
    TEX_PLANKS,
    TEX_COUNT
};

static uint8_t worldMap[MAP_H][MAP_W];
static uint8_t groundMap[MAP_H][MAP_W];   /* texture id for the floor */

/*
 * textures[]     : normal brightness
 * texturesDark[] : 2 steps darker, used for walls hit on their Y side
 *                  (gives the classic lit/unlit face look with no
 *                  per-pixel branching in the wall loop).
 */
static uint8_t textures[TEX_COUNT][TEX_PIXELS];
static uint8_t texturesDark[TEX_COUNT][TEX_PIXELS];

static float sineTable[TRIG_SIZE];
static float cosineTable[TRIG_SIZE];

static int16_t  rayCameraX[RAY_COUNT];    /* 8.8 fixed point, -256..256 */
static uint16_t recipTable[512];          /* 65536 / i                  */
static float    floorRowScale[SH];        /* PROJECTION / (row + 1)     */

/*
 * Per-column wall data.  Depth is in world units; top/bottom are the
 * screen rows the wall occupies, so props can be occluded vertically as
 * well as by distance (needed for roofs that rise above the walls).
 */
static uint16_t wallDepth[RAY_COUNT];
static int16_t  wallTop[RAY_COUNT];
static int16_t  wallBottom[RAY_COUNT];

/* =========================================================================
 * PLAYER
 * ========================================================================= */

typedef enum {
    TOOL_COPY = 0,
    TOOL_DRAG,
    TOOL_DELETE,
    TOOL_ROCKET
} Tool;

typedef struct {
    float x;
    float y;
    float z;
    float vz;

    float facing;
    float cameraYaw;

    float cameraDistance;
    float cameraMaximum;

    float walkPhase;
    float walkAmount;

    float attackTimer;

    float health;
    float respawnTimer;

    bool onGround;
    bool dead;

    Tool tool;
} Player;

static Player player;

static int displayedFPS = 0;

static float cameraX;
static float cameraY;
static float cameraZ = EYE_HEIGHT;

static float cameraCos;
static float cameraSin;

/* =========================================================================
 * BUILDABLE WORLD OBJECTS
 * ========================================================================= */

typedef struct {
    float x;
    float y;
    float z;      /* bottom */

    float sx;
    float sy;
    float sz;

    uint8_t material;
    bool active;
    bool solid;
} WorldPart;

static WorldPart worldParts[MAX_WORLD_PARTS];
static int worldPartCount = 0;

static int hoverPart = -1;
static int heldPart = -1;
static int cloneTarget = -1;
static float heldDistance = 48.0f;

/* =========================================================================
 * PROJECTILE / EFFECTS
 * ========================================================================= */

typedef struct {
    float x;
    float y;

    float dx;
    float dy;

    float z;
    float lifetime;

    bool active;
} Projectile;

static Projectile rocket;

typedef struct {
    float x;
    float y;
    float z;

    float lifetime;
} Explosion;

static Explosion explosion;

typedef struct {
    float x, y, z;
    float vx, vy, vz;
    float size;
    uint8_t material;
} Debris;

static Debris debris[MAX_DEBRIS];
static int debrisCount = 0;

typedef struct {
    float angle;
    int16_t y;
    int16_t size;
} Cloud;

static const Cloud clouds[] = {
    {-2.7f, 30, 22}, {-1.8f, 52, 16}, {-0.7f, 24, 26}, { 0.3f, 48, 18},
    { 1.2f, 28, 24}, { 2.1f, 52, 20}, { 3.0f, 36, 18}
};

static float cloudDrift = 0.0f;

/* =========================================================================
 * MATH
 * ========================================================================= */

static float clampf(float value, float minimum, float maximum) {
    if (value < minimum)
        return minimum;

    if (value > maximum)
        return maximum;

    return value;
}

static float wrapAngle(float angle) {
    while (angle > PI_F)
        angle -= 2.0f * PI_F;

    while (angle < -PI_F)
        angle += 2.0f * PI_F;

    return angle;
}

static int roundFloat(float value) {
    return (int)(value + (value >= 0.0f ? 0.5f : -0.5f));
}

/*
 * The +8192.5 offset keeps the index positive for any angle down to about
 * -100 rad and rounds to nearest (plain truncation was biased for
 * negative angles).  8192 is a multiple of TRIG_SIZE so it does not
 * change the result.
 */
static float fastSin(float angle) {
    int index = (int)(angle * ((float)TRIG_SIZE / (2.0f * PI_F)) + 8192.5f);
    return sineTable[index & TRIG_MASK];
}

static float fastCos(float angle) {
    int index = (int)(angle * ((float)TRIG_SIZE / (2.0f * PI_F)) + 8192.5f);
    return cosineTable[index & TRIG_MASK];
}

static void initMath(void) {
    for (int i = 0; i < TRIG_SIZE; i++) {
        float angle = (float)i * (2.0f * PI_F / (float)TRIG_SIZE);

        sineTable[i] = sinf(angle);
        cosineTable[i] = cosf(angle);
    }

    for (int i = 0; i < RAY_COUNT; i++) {
        rayCameraX[i] =
            (int16_t)(((2 * i + 1 - RAY_COUNT) * 256) / RAY_COUNT);
    }

    recipTable[0] = 65535;

    for (int i = 1; i < 512; i++) {
        long v = 65536L / i;

        if (v > 65535L)
            v = 65535L;

        recipTable[i] = (uint16_t)v;
    }

    /* Indexed by row offset below the horizon. */
    for (int row = 0; row < SH; row++)
        floorRowScale[row] = PROJECTION / (float)(row + 1);
}

static uint32_t hash2(int x, int y) {
    uint32_t h =
        (uint32_t)x * 374761393u
        + (uint32_t)y * 668265263u;

    h = (h ^ (h >> 13)) * 1274126177u;

    return h ^ (h >> 16);
}

/* =========================================================================
 * PALETTE
 * ========================================================================= */

static void initPalette(void) {
    for (int m = 0; m < MAT_COUNT; m++) {
        for (int l = 0; l < 16; l++) {
            float factor;

            if (l <= 10)
                factor = 0.16f + 0.084f * (float)l;
            else
                factor = 1.0f + 0.09f * (float)(l - 10);

            float r = clampf((float)materialRGB[m][0] * factor, 0, 255);
            float g = clampf((float)materialRGB[m][1] * factor, 0, 255);
            float b = clampf((float)materialRGB[m][2] * factor, 0, 255);

            gfx_palette[(m << 4) | l] =
                gfx_RGBTo1555((uint8_t)r, (uint8_t)g, (uint8_t)b);
        }
    }

    gfx_palette[UI_BLACK]       = gfx_RGBTo1555(0, 0, 0);
    gfx_palette[UI_WHITE]       = gfx_RGBTo1555(255, 255, 255);
    gfx_palette[UI_DARK]        = gfx_RGBTo1555(40, 40, 45);
    gfx_palette[UI_GRAY]        = gfx_RGBTo1555(160, 160, 165);
    gfx_palette[UI_GREEN]       = gfx_RGBTo1555(0, 200, 0);
    gfx_palette[UI_YELLOW]      = gfx_RGBTo1555(255, 220, 50);
    gfx_palette[UI_RED]         = gfx_RGBTo1555(200, 0, 0);
    gfx_palette[UI_ORANGE]      = gfx_RGBTo1555(255, 130, 0);
    gfx_palette[UI_FIRE]        = gfx_RGBTo1555(255, 235, 80);
    gfx_palette[UI_SELECT]      = gfx_RGBTo1555(0, 162, 255);
    gfx_palette[UI_CLOUD]       = gfx_RGBTo1555(238, 246, 255);
    gfx_palette[UI_CLOUDSHADE]  = gfx_RGBTo1555(196, 218, 242);
    gfx_palette[UI_SUNGLOW]     = gfx_RGBTo1555(255, 246, 170);
}

static uint8_t shadeColor(uint8_t c, int amount) {
    int light = c & 15;

    if (light > amount)
        return (uint8_t)(c - amount);

    return (uint8_t)(c & 0xF0);
}

/* =========================================================================
 * TEXTURE GENERATION
 * ========================================================================= */

static void buildTextures(void) {
    for (int y = 0; y < TEX_SIZE; y++) {
        for (int x = 0; x < TEX_SIZE; x++) {
            int index = y * TEX_SIZE + x;
            int bx = x & 7;
            int by = y & 7;
            int light;

            /* Classic studded baseplate: bevelled 1x1 studs. */

            bool stud =
                bx >= 2 && bx <= 5 && by >= 2 && by <= 5;

            light = 9;

            if (stud) {
                if (by == 2)
                    light = 14;
                else if (by == 5)
                    light = 7;
                else
                    light = 11;
            }

            textures[TEX_BASEPLATE][index] = PIXEL(MAT_GRASS, light);

            /* Stone border. */

            light = 10 + (int)(hash2(x, y) & 1);

            if ((x & 15) == 0 || (y & 15) == 0)
                light = 7;

            textures[TEX_STONE][index] = PIXEL(MAT_STONE, light);

            /* Red brick. */

            {
                int row = y >> 3;
                int offset = (row & 1) ? 8 : 0;

                int tx = (x + offset) & 15;
                int ty = y & 7;

                if (tx == 0 || ty == 0)
                    textures[TEX_BRICK][index] = PIXEL(MAT_STONE, 7);
                else
                    textures[TEX_BRICK][index] = PIXEL(MAT_BRICK, 10);
            }

            /* Tan plaster. */

            light = 11;

            if ((x & 15) == 0 || (y & 15) == 0)
                light = 9;

            textures[TEX_PLASTER][index] = PIXEL(MAT_TAN, light);

            /* Wood. */

            light = 8;

            if ((x & 7) == 0)
                light = 6;

            textures[TEX_WOOD][index] = PIXEL(MAT_WOOD, light);

            /* Leaves. */

            light = 8 + (int)(hash2(x >> 1, y >> 1) & 2);

            textures[TEX_LEAVES][index] = PIXEL(MAT_LEAF, light);

            /* Window. */

            if (x < 3 || x > 28 || y < 3 || y > 28
                || (x & 15) == 0 || (y & 15) == 0) {
                textures[TEX_GLASS][index] = PIXEL(MAT_WOOD, 8);
            } else {
                textures[TEX_GLASS][index] = PIXEL(MAT_GLASS, 13);
            }

            /* Stone path slabs. */

            light = 10 + (int)(hash2(x >> 4, y >> 4) & 1);

            if ((x & 15) == 0 || (y & 15) == 0)
                light = 6;

            textures[TEX_PATH][index] = PIXEL(MAT_STONE, light);

            /* Wooden plank floor. */

            {
                int board = y >> 3;
                int off = (board & 1) ? 16 : 0;
                int px = (x + off) & 31;

                light = 9 + (int)(hash2(board, (x + off) >> 5) & 1);

                if ((y & 7) == 0 || px == 0)
                    light = 6;

                textures[TEX_PLANKS][index] = PIXEL(MAT_WOOD, light);
            }
        }
    }

    for (int t = 0; t < TEX_COUNT; t++) {
        for (int i = 0; i < TEX_PIXELS; i++)
            texturesDark[t][i] = shadeColor(textures[t][i], 2);
    }
}

static uint8_t textureForTile(uint8_t tile) {
    switch (tile) {
        case TILE_BRICK:  return TEX_BRICK;
        case TILE_TAN:    return TEX_PLASTER;
        case TILE_GLASS:  return TEX_GLASS;
        case TILE_WOOD:   return TEX_WOOD;
        case TILE_LEAVES: return TEX_LEAVES;
        case TILE_STONE:
        default:          return TEX_STONE;
    }
}

/* =========================================================================
 * MAP GENERATION
 * ========================================================================= */

static void setMapTile(int x, int y, uint8_t tile) {
    if (x < 0 || y < 0 || x >= MAP_W || y >= MAP_H)
        return;

    worldMap[y][x] = tile;
}

static void setGround(int x, int y, uint8_t tex) {
    if (x < 0 || y < 0 || x >= MAP_W || y >= MAP_H)
        return;

    groundMap[y][x] = tex;
}

static void buildMap(void) {
    memset(worldMap, 0, sizeof(worldMap));
    memset(groundMap, TEX_BASEPLATE, sizeof(groundMap));

    for (int x = 0; x < MAP_W; x++) {
        setMapTile(x, 0, TILE_STONE);
        setMapTile(x, MAP_H - 1, TILE_STONE);
    }

    for (int y = 0; y < MAP_H; y++) {
        setMapTile(0, y, TILE_STONE);
        setMapTile(MAP_W - 1, y, TILE_STONE);
    }

    /* House. */

    const int hx = 10;
    const int hy = 7;
    const int hw = 6;
    const int hh = 5;

    for (int x = hx; x < hx + hw; x++) {
        setMapTile(x, hy, TILE_TAN);
        setMapTile(x, hy + hh, TILE_BRICK);
    }

    for (int y = hy; y <= hy + hh; y++) {
        setMapTile(hx, y, TILE_TAN);
        setMapTile(hx + hw - 1, y, TILE_TAN);
    }

    /* Front door opening. */
    setMapTile(hx + 3, hy + hh, TILE_EMPTY);

    /* Windows (front-left, front-right, and one on each side). */
    setMapTile(hx + 1, hy, TILE_GLASS);
    setMapTile(hx + 4, hy, TILE_GLASS);
    setMapTile(hx, hy + 2, TILE_GLASS);
    setMapTile(hx + hw - 1, hy + 2, TILE_GLASS);

    /* Wooden plank floor inside. */
    for (int y = hy + 1; y < hy + hh; y++) {
        for (int x = hx + 1; x < hx + hw - 1; x++)
            setGround(x, y, TEX_PLANKS);
    }

    /* Stone path from the door to the spawn plaza. */
    for (int y = hy + hh; y <= 18; y++)
        setGround(hx + 3, y, TEX_PATH);

    for (int x = hx + 2; x <= hx + 4; x++)
        setGround(x, 18, TEX_PATH);
}

/* =========================================================================
 * WORLD PARTS & COLLISION
 * ========================================================================= */

static uint8_t tileAt(float x, float y) {
    if (x < 0 || y < 0)
        return TILE_STONE;

    int tx = (int)(x * INV_TILE_SIZE);
    int ty = (int)(y * INV_TILE_SIZE);

    if (tx < 0 || ty < 0 || tx >= MAP_W || ty >= MAP_H)
        return TILE_STONE;

    return worldMap[ty][tx];
}

static bool solidBox(float x, float y, float radius) {
    return tileAt(x - radius, y - radius) != TILE_EMPTY
        || tileAt(x + radius, y - radius) != TILE_EMPTY
        || tileAt(x - radius, y + radius) != TILE_EMPTY
        || tileAt(x + radius, y + radius) != TILE_EMPTY;
}

static int addWorldPart(
    float x, float y, float z,
    float sx, float sy, float sz,
    uint8_t material, bool solid
) {
    int index = -1;

    /* Reuse deleted slots first so Delete never wastes capacity. */
    for (int i = 0; i < worldPartCount; i++) {
        if (!worldParts[i].active) {
            index = i;
            break;
        }
    }

    if (index < 0) {
        if (worldPartCount >= MAX_WORLD_PARTS)
            return -1;

        index = worldPartCount++;
    }

    WorldPart *p = &worldParts[index];

    p->x = x;
    p->y = y;
    p->z = z;

    p->sx = sx;
    p->sy = sy;
    p->sz = sz;

    p->material = material;
    p->active = true;
    p->solid = solid;

    return index;
}

/* Highest solid surface the feet can step onto. */
static float groundHeight(float x, float y, float z) {
    float best = 0.0f;

    for (int i = 0; i < worldPartCount; i++) {
        const WorldPart *p = &worldParts[i];

        if (!p->active || !p->solid)
            continue;

        if (fabsf(x - p->x) > p->sx * 0.5f + PLAYER_RADIUS * 0.5f)
            continue;

        if (fabsf(y - p->y) > p->sy * 0.5f + PLAYER_RADIUS * 0.5f)
            continue;

        float top = p->z + p->sz;

        if (top <= z + STEP_HEIGHT && top > best)
            best = top;
    }

    return best;
}

static bool partBlocks(float x, float y, float z, float r) {
    for (int i = 0; i < worldPartCount; i++) {
        const WorldPart *p = &worldParts[i];

        if (!p->active || !p->solid)
            continue;

        if (fabsf(x - p->x) >= p->sx * 0.5f + r)
            continue;

        if (fabsf(y - p->y) >= p->sy * 0.5f + r)
            continue;

        float top = p->z + p->sz;

        if (top > z + STEP_HEIGHT && p->z < z + BODY_HEIGHT)
            return true;
    }

    return false;
}

static bool rocketHitsPart(float x, float y, float z) {
    for (int i = 0; i < worldPartCount; i++) {
        const WorldPart *p = &worldParts[i];

        if (!p->active)
            continue;

        if (fabsf(x - p->x) > p->sx * 0.5f + 2.0f)
            continue;

        if (fabsf(y - p->y) > p->sy * 0.5f + 2.0f)
            continue;

        if (z >= p->z - 3.0f && z <= p->z + p->sz + 3.0f)
            return true;
    }

    return false;
}

/* =========================================================================
 * DECORATIONS
 * ========================================================================= */

static void addTree(int tileX, int tileY) {
    float x = ((float)tileX + 0.5f) * TILE_SIZE;
    float y = ((float)tileY + 0.5f) * TILE_SIZE;

    addWorldPart(x, y,  0, 12, 12, 44, MAT_WOOD, true);
    addWorldPart(x, y, 44, 44, 44, 24, MAT_LEAF, false);
    addWorldPart(x, y, 68, 28, 28, 16, MAT_LEAF, false);
}

static void addFence(float x, float y, int count) {
    const float spacing = 20.0f;

    for (int i = 0; i < count; i++) {
        addWorldPart(
            x + (float)i * spacing, y, 0,
            6, 4, 18, MAT_WHITE, true
        );
    }

    addWorldPart(
        x + (float)(count - 1) * spacing * 0.5f, y, 7,
        (float)(count - 1) * spacing, 3, 3, MAT_WHITE, false
    );
}

static void addFlower(float x, float y, uint8_t bloom) {
    addWorldPart(x, y, 0, 2, 2, 6, MAT_LEAF, false);
    addWorldPart(x, y, 6, 7, 7, 4, bloom, false);
}

static void buildDecorations(void) {
    /* SpawnLocation. */
    addWorldPart(SPAWN_X, SPAWN_Y, 0, 28, 28, 2, MAT_STONE, false);

    /* Garden trees. */
    addTree(4, 5);
    addTree(19, 5);
    addTree(4, 15);
    addTree(20, 15);
    addTree(21, 9);

    /* Fence with a gate where the path passes through. */
    addFence(704.0f, 992.0f, 7);
    addFence(904.0f, 992.0f, 7);

    /* Flowers and bushes. */
    addFlower(9.2f * TILE_SIZE, 9.0f * TILE_SIZE, MAT_RED);
    addFlower(9.2f * TILE_SIZE, 10.0f * TILE_SIZE, MAT_YELLOW);
    addFlower(16.5f * TILE_SIZE, 9.0f * TILE_SIZE, MAT_YELLOW);
    addFlower(16.5f * TILE_SIZE, 10.0f * TILE_SIZE, MAT_RED);

    addWorldPart(9.4f * TILE_SIZE, 12.6f * TILE_SIZE, 0, 22, 22, 14,
                 MAT_LEAF, true);
    addWorldPart(16.4f * TILE_SIZE, 12.6f * TILE_SIZE, 0, 22, 22, 14,
                 MAT_LEAF, true);

    /* Stepped roof (drawn above the raycast walls). */
    {
        float cx = 13.0f * TILE_SIZE;
        float cy = 9.97f * TILE_SIZE;

        addWorldPart(cx, cy, 64, 400, 400, 8, MAT_RED, false);
        addWorldPart(cx, cy, 72, 304, 304, 8, MAT_RED, false);
        addWorldPart(cx, cy, 80, 208, 208, 8, MAT_RED, false);
        addWorldPart(cx, cy, 88, 112, 112, 8, MAT_RED, false);
    }

    /* Furniture. */
    addWorldPart(800, 608, 0, 6, 6, 12, MAT_WOOD, true);
    addWorldPart(800, 608, 12, 32, 20, 3, MAT_WOOD, true);
    addWorldPart(768, 648, 0, 10, 10, 8, MAT_RED, true);
    addWorldPart(832, 648, 0, 10, 10, 8, MAT_RED, true);

    /* Seesaw. */
    addWorldPart(5.5f * TILE_SIZE, 13.5f * TILE_SIZE, 0, 8, 8, 10,
                 MAT_STONE, true);
    addWorldPart(5.5f * TILE_SIZE, 13.5f * TILE_SIZE, 10, 56, 10, 3,
                 MAT_YELLOW, true);
}

/* =========================================================================
 * PROJECTION
 * ========================================================================= */

static bool project(
    float wx, float wy, float wz,
    int *sx, int *sy, float *depth
) {
    float dx = wx - cameraX;
    float dy = wy - cameraY;

    float forward = dx * cameraCos + dy * cameraSin;
    float side = -dx * cameraSin + dy * cameraCos;

    if (forward < 6.0f)
        return false;

    float scale = PROJECTION / forward;

    *sx = SW / 2 + roundFloat(side * scale);
    *sy = HORIZON - roundFloat((wz - cameraZ) * scale);

    *depth = forward;

    return true;
}

/* =========================================================================
 * SKY
 * ========================================================================= */

static void drawSky(void) {
    /*
     * The sky gradient only has five distinct brightness levels, so five
     * hardware-accelerated rectangle fills replace 104 row memsets.
     */

    for (int k = 0; k < 5; k++) {
        int y0 = (k * HORIZON) / 5;
        int y1 = ((k + 1) * HORIZON) / 5;

        gfx_SetColor(PIXEL(MAT_SKY, 7 + k));
        gfx_FillRectangle_NoClip(0, y0, SW, y1 - y0);
    }
}

static void drawSkyObjects(void) {
    /* Sun. */
    {
        float da = wrapAngle(SUN_ANGLE - player.cameraYaw);
        float c = fastCos(da);

        if (c > 0.3f) {
            int sx = SW / 2 + roundFloat(PROJECTION * fastSin(da) / c);

            gfx_SetColor(UI_SUNGLOW);
            gfx_FillCircle(sx, 34, 15);

            gfx_SetColor(UI_FIRE);
            gfx_FillCircle(sx, 34, 9);
        }
    }

    /* Slowly drifting flat clouds. */
    for (unsigned i = 0; i < sizeof(clouds) / sizeof(clouds[0]); i++) {
        float da = wrapAngle(clouds[i].angle + cloudDrift - player.cameraYaw);
        float c = fastCos(da);

        if (c < 0.3f)
            continue;

        int cx = SW / 2 + roundFloat(PROJECTION * fastSin(da) / c);
        int s = clouds[i].size;
        int cy = clouds[i].y;

        if (cx < -s * 2 || cx > SW + s * 2)
            continue;

        gfx_SetColor(UI_CLOUDSHADE);
        gfx_FillEllipse(cx, cy + 3, s, s / 3);

        gfx_SetColor(UI_CLOUD);
        gfx_FillEllipse(cx, cy, s, s / 3);
        gfx_FillEllipse(cx - s / 2, cy - 3, s / 2, s / 4);
        gfx_FillEllipse(cx + s / 3, cy - 4, s / 2, s / 4);
    }
}

/* =========================================================================
 * FLOOR
 * ========================================================================= */

static void drawFloor(void) {
    uint8_t *buffer = (uint8_t *)gfx_vbuffer;

    const float rightX = -cameraSin;
    const float rightY = cameraCos;

    const uint8_t fogColor = PIXEL(MAT_SKY, 11);   /* horizon haze */

    for (int y = HORIZON; y < SH; y += 2) {
        float rowDistance = cameraZ * floorRowScale[y - HORIZON];

        uint8_t *row0 = buffer + y * SW;

        /* Beyond the draw distance the floor is solid haze. */
        if (rowDistance >= FOG_END) {
            memset(row0, fogColor, SW * 2);
            continue;
        }

        int fogLevel = 0;

        if (rowDistance > FOG_START) {
            fogLevel = (int)(
                (rowDistance - FOG_START)
                * (4.0f / (FOG_END - FOG_START))
            );
        }

        float lateral = rowDistance / PROJECTION;

        float worldX =
            cameraX + cameraCos * rowDistance
            + rightX * (-159.0f) * lateral;

        float worldY =
            cameraY + cameraSin * rowDistance
            + rightY * (-159.0f) * lateral;

        int fx = (int)(worldX * 256.0f);
        int fy = (int)(worldY * 256.0f);

        int stepX = (int)(rightX * 2.0f * lateral * 256.0f);
        int stepY = (int)(rightY * 2.0f * lateral * 256.0f);

        uint16_t *dst = (uint16_t *)row0;

        int rowPair = (y >> 1) & 1;

        for (int x = 0; x < RAY_COUNT; x++) {
            int tileX = fx >> 14;      /* 256 * 64 = 2^14 */
            int tileY = fy >> 14;

            const uint8_t *tex = textures[TEX_BASEPLATE];

            if ((unsigned)tileX < MAP_W && (unsigned)tileY < MAP_H)
                tex = textures[groundMap[tileY][tileX]];

            uint8_t color =
                tex[(((fy >> 8) & 31) << 5) | ((fx >> 8) & 31)];

            /* 2x2 ordered dither blends the far floor into the sky. */
            if (fogLevel > 0
                && (int)(((x & 1) << 1) | rowPair) < fogLevel) {
                color = fogColor;
            }

            dst[x] = (uint16_t)((uint16_t)color * 257u);

            fx += stepX;
            fy += stepY;
        }

        /* The renderer works in row pairs: copy the second row. */
        memcpy(row0 + SW, row0, SW);
    }
}

/* =========================================================================
 * WALL RENDERER  (fixed point DDA)
 *
 * Positions are 8.8 fixed point in tile units; ray components are 8.8.
 * Distances are therefore in 1/256 tile = 1/4 world unit.
 * ========================================================================= */

static void drawWalls(void) {
    uint8_t *buffer = (uint8_t *)gfx_vbuffer;

    const int32_t dirX = (int32_t)(cameraCos * 256.0f);
    const int32_t dirY = (int32_t)(cameraSin * 256.0f);

    const int32_t planeX = (int32_t)(-cameraSin * FOV_PLANE * 256.0f);
    const int32_t planeY = (int32_t)(cameraCos * FOV_PLANE * 256.0f);

    const int32_t posX = (int32_t)(cameraX * 4.0f);
    const int32_t posY = (int32_t)(cameraY * 4.0f);

    const int eyeI = roundFloat(cameraZ);

    const int mapX0 = (int)(posX >> 8);
    const int mapY0 = (int)(posY >> 8);

    const int32_t fracX = posX & 255;
    const int32_t fracY = posY & 255;

    for (int i = 0; i < RAY_COUNT; i++) {
        int32_t cx = rayCameraX[i];

        int32_t rayX = dirX + ((planeX * cx) >> 8);
        int32_t rayY = dirY + ((planeY * cx) >> 8);

        int mapX = mapX0;
        int mapY = mapY0;

        int32_t ax = rayX < 0 ? -rayX : rayX;
        int32_t ay = rayY < 0 ? -rayY : rayY;

        if (ax > 511) ax = 511;
        if (ay > 511) ay = 511;

        int32_t deltaX = recipTable[ax];
        int32_t deltaY = recipTable[ay];

        int stepX;
        int stepY;

        int32_t sideX;
        int32_t sideY;

        if (rayX < 0) {
            stepX = -1;
            sideX = (fracX * deltaX) >> 8;
        } else {
            stepX = 1;
            sideX = ((256 - fracX) * deltaX) >> 8;
        }

        if (rayY < 0) {
            stepY = -1;
            sideY = (fracY * deltaY) >> 8;
        } else {
            stepY = 1;
            sideY = ((256 - fracY) * deltaY) >> 8;
        }

        int side = 0;
        uint8_t tile = TILE_STONE;
        int32_t distance = 0;

        for (int step = 0; step < MAP_W + MAP_H; step++) {
            if (sideX < sideY) {
                distance = sideX;
                sideX += deltaX;
                mapX += stepX;
                side = 0;
            } else {
                distance = sideY;
                sideY += deltaY;
                mapY += stepY;
                side = 1;
            }

            if (mapX < 0 || mapY < 0 || mapX >= MAP_W || mapY >= MAP_H) {
                tile = TILE_STONE;
                break;
            }

            tile = worldMap[mapY][mapX];

            if (tile != TILE_EMPTY)
                break;
        }

        if (distance < 13)
            distance = 13;

        int32_t depthUnits = distance >> 2;

        if (depthUnits > 65535)
            depthUnits = 65535;

        wallDepth[i] = (uint16_t)depthUnits;

        /* Texture column. */

        int32_t hit;

        if (side == 0)
            hit = posY + ((distance * rayY) >> 8);
        else
            hit = posX + ((distance * rayX) >> 8);

        int texX = (int)((hit & 255) >> 3);

        if ((side == 0 && rayX > 0) || (side == 1 && rayY < 0))
            texX = TEX_SIZE - 1 - texX;

        /* Vertical extent, integer only. */

        int up = ((WALL_HEIGHT - eyeI) * WALL_NUM) / (int)distance;
        int down = (eyeI * WALL_NUM) / (int)distance;

        int top = HORIZON - up;
        int bottom = HORIZON + down;

        int fullHeight = bottom - top + 1;

        if (fullHeight < 1)
            fullHeight = 1;

        /* 16.16 texture step. */
        long texStep = ((long)TEX_SIZE << 16) / fullHeight;
        long texPos = 0;

        int y0 = top;
        int y1 = bottom;

        /*
         * Crop instead of squash: when the wall is taller than the screen
         * the texture must start part-way down (the old code compressed
         * the whole texture into the visible rows).
         */
        if (y0 < 0) {
            texPos = (long)(-y0) * texStep;
            y0 = 0;
        }

        if (y1 >= SH)
            y1 = SH - 1;

        wallTop[i] = (int16_t)(y0 < 0 ? 0 : y0);
        wallBottom[i] = (int16_t)(y1 >= SH ? SH - 1 : y1);

        if (y1 < y0)
            continue;

        const uint8_t *texColumn =
            (side ? texturesDark[textureForTile(tile)]
                  : textures[textureForTile(tile)]) + texX;

        uint16_t *p = (uint16_t *)(buffer + y0 * SW + i * 2);

        for (int y = y0; y <= y1; y++) {
            uint8_t color = texColumn[(int)(texPos >> 16) << 5];

            *p = (uint16_t)((uint16_t)color * 257u);

            p += SW / 2;
            texPos += texStep;
        }
    }
}

/* =========================================================================
 * OCCLUDED RECTANGLE
 *
 * Fills a rectangle belonging to an object at 'depth' world units.
 * Each 2-pixel screen column is tested against the wall in that column:
 *   - wall farther than the object  -> draw everything
 *   - wall nearer                   -> draw only the parts above and below
 *                                      the wall's screen extent
 * Runs of unobstructed columns are merged into a single fill.
 * ========================================================================= */

static void fillOccluded(
    int x, int y, int w, int h,
    int depth, uint8_t color
) {
    int x0 = x < 0 ? 0 : x;
    int x1 = (x + w) > SW ? SW : (x + w);
    int y0 = y < 0 ? 0 : y;
    int y1 = (y + h) > SH ? SH : (y + h);

    if (x0 >= x1 || y0 >= y1)
        return;

    gfx_SetColor(color);

    int runStart = -1;
    int runEnd = 0;

    int firstCol = x0 >> 1;
    int lastCol = (x1 - 1) >> 1;

    for (int c = firstCol; c <= lastCol; c++) {
        int cx0 = c << 1;
        int cx1 = cx0 + 2;

        if (cx0 < x0) cx0 = x0;
        if (cx1 > x1) cx1 = x1;

        if (depth <= (int)wallDepth[c]) {
            if (runStart < 0)
                runStart = cx0;

            runEnd = cx1;
            continue;
        }

        if (runStart >= 0) {
            gfx_FillRectangle_NoClip(runStart, y0, runEnd - runStart, y1 - y0);
            runStart = -1;
        }

        int aboveEnd = wallTop[c];

        if (aboveEnd > y1)
            aboveEnd = y1;

        if (aboveEnd > y0)
            gfx_FillRectangle_NoClip(cx0, y0, cx1 - cx0, aboveEnd - y0);

        int belowStart = wallBottom[c] + 1;

        if (belowStart < y0)
            belowStart = y0;

        if (belowStart < y1)
            gfx_FillRectangle_NoClip(cx0, belowStart, cx1 - cx0, y1 - belowStart);
    }

    if (runStart >= 0)
        gfx_FillRectangle_NoClip(runStart, y0, runEnd - runStart, y1 - y0);
}

/* =========================================================================
 * BOX RENDERER
 *
 * Draws an oriented box as:
 *   - a front face sized at its nearest depth
 *   - a lighter top face when the camera is above it (with studs)
 * Screen width / depth extents use the box's real orientation, so a part
 * turned 45 degrees looks wider than one seen face-on.
 * ========================================================================= */

static int lastLeft, lastTop, lastRight, lastBottom;
static int lastFrontLeft, lastFrontTop, lastFrontW, lastFrontH;
static int lastDepth;

static bool drawBox(
    float x, float y, float z,
    float sx, float sy, float sz,
    float ux, float uy,
    uint8_t material, bool studs
) {
    float dx = x - cameraX;
    float dy = y - cameraY;

    float fwd = dx * cameraCos + dy * cameraSin;
    float side = -dx * cameraSin + dy * cameraCos;

    float vx = -uy;
    float vy = ux;

    float widthExtent =
        sx * fabsf(-ux * cameraSin + uy * cameraCos)
        + sy * fabsf(-vx * cameraSin + vy * cameraCos);

    float depthExtent =
        sx * fabsf(ux * cameraCos + uy * cameraSin)
        + sy * fabsf(vx * cameraCos + vy * cameraSin);

    float nearDepth = fwd - depthExtent * 0.5f;
    float farDepth = fwd + depthExtent * 0.5f;

    if (farDepth < 8.0f || nearDepth > MAX_DRAW_DISTANCE)
        return false;

    if (nearDepth < 8.0f)
        nearDepth = 8.0f;

    float scale = PROJECTION / nearDepth;

    int widthPx = roundFloat(widthExtent * scale);

    if (widthPx < 1)
        widthPx = 1;

    int centerX = SW / 2 + roundFloat(side * scale);
    int left = centerX - widthPx / 2;

    if (left >= SW || left + widthPx <= 0)
        return false;

    float zTop = z + sz;

    int yTop = HORIZON - roundFloat((zTop - cameraZ) * scale);
    int yBottom = HORIZON - roundFloat((z - cameraZ) * scale);

    int height = yBottom - yTop;

    if (height < 1)
        height = 1;

    if (yTop >= SH || yTop + height <= 0)
    {
        /* The front face is off screen; a top face might still show. */
        if (!(cameraZ > zTop && yTop > 0))
            return false;
    }

    int depthInt = (int)nearDepth;

    lastLeft = left;
    lastRight = left + widthPx;
    lastTop = yTop;
    lastBottom = yTop + height;
    lastFrontLeft = left;
    lastFrontTop = yTop;
    lastFrontW = widthPx;
    lastFrontH = height;
    lastDepth = depthInt;

    /* Front face with a small bevel. */

    fillOccluded(left, yTop, widthPx, height, depthInt, PIXEL(material, 10));

    if (height >= 3 && widthPx >= 3) {
        fillOccluded(left, yBottom - 1, widthPx, 1, depthInt, PIXEL(material, 7));
        fillOccluded(left + widthPx - 1, yTop, 1, height, depthInt,
                     PIXEL(material, 8));
    }

    /* Top face. */

    if (cameraZ > zTop + 0.5f) {
        float backScale = PROJECTION / farDepth;

        int yBack = HORIZON - roundFloat((zTop - cameraZ) * backScale);
        int faceH = yTop - yBack;

        if (faceH >= 1) {
            int backW = roundFloat(widthExtent * backScale);
            int faceW = (widthPx + backW) / 2;

            if (faceW < 1)
                faceW = 1;

            int faceLeft = centerX - faceW / 2;

            fillOccluded(faceLeft, yBack, faceW, faceH, depthInt,
                         PIXEL(material, 13));

            lastTop = yBack;

            /* Studs: one per stud-sized cell, capped for speed. */

            if (studs && faceH >= 3 && faceW >= 6 && nearDepth < 600.0f) {
                int nx = roundFloat(widthExtent / STUD);
                int ny = roundFloat(depthExtent / STUD);

                if (nx < 1) nx = 1;
                if (ny < 1) ny = 1;

                if (nx * ny <= 36) {
                    int stW = faceW / (nx * 2);
                    int stH = faceH / (ny * 2);

                    if (stW < 1) stW = 1;
                    if (stH < 1) stH = 1;

                    uint8_t studColor = PIXEL(material, 15);

                    for (int j = 0; j < ny; j++) {
                        int sy2 = yBack + ((j * 2 + 1) * faceH) / (ny * 2);

                        for (int i = 0; i < nx; i++) {
                            int sx2 = faceLeft + ((i * 2 + 1) * faceW) / (nx * 2);

                            fillOccluded(
                                sx2 - stW / 2, sy2 - stH / 2,
                                stW, stH, depthInt, studColor
                            );
                        }
                    }
                }
            }
        }
    }

    return true;
}

static void drawSelectionOutline(void) {
    gfx_SetColor(UI_SELECT);

    gfx_Rectangle(
        lastLeft - 1,
        lastTop - 1,
        (lastRight - lastLeft) + 2,
        (lastBottom - lastTop) + 2
    );
}

/* =========================================================================
 * CHARACTER  (classic Roblox "noob")
 *
 * Proportions in studs: head 1.5x1x1, torso 2x2x1, arms and legs 1x2x1.
 * Colours: bright yellow head and arms, bright blue torso, bright green legs.
 * ========================================================================= */

typedef struct {
    float x, y, z;
    float sx, sy, sz;
    uint8_t material;
    bool isHead;
} Limb;

#define LIMB_COUNT 7

static Limb limbs[LIMB_COUNT];
static int limbCount = 0;
static float bodyRightX = 1.0f;
static float bodyRightY = 0.0f;

static void buildLimbs(void) {
    float fx = fastCos(player.facing);
    float fy = fastSin(player.facing);

    float rx = -fy;
    float ry = fx;

    bodyRightX = rx;
    bodyRightY = ry;

    float swing = fastSin(player.walkPhase) * player.walkAmount;

    float legSwing = swing * 5.0f;
    float armSwing = -swing * 4.0f;

    float bx = player.x;
    float by = player.y;
    float bz = player.z;

    int n = 0;

    /* Legs. */
    limbs[n++] = (Limb){
        bx - rx * 4.0f + fx * legSwing, by - ry * 4.0f + fy * legSwing, bz,
        8, 8, 16, MAT_GRASS, false
    };

    limbs[n++] = (Limb){
        bx + rx * 4.0f - fx * legSwing, by + ry * 4.0f - fy * legSwing, bz,
        8, 8, 16, MAT_GRASS, false
    };

    /* Torso. */
    limbs[n++] = (Limb){
        bx, by, bz + 16,
        16, 8, 16, MAT_BLUE, false
    };

    /* Left arm. */
    limbs[n++] = (Limb){
        bx - rx * 12.0f + fx * armSwing, by - ry * 12.0f + fy * armSwing,
        bz + 16,
        8, 8, 16, MAT_YELLOW, false
    };

    /* Right arm: raised forward while using a tool. */
    {
        float armX = bx + rx * 12.0f - fx * armSwing;
        float armY = by + ry * 12.0f - fy * armSwing;
        float armZ = bz + 16;

        float handX = armX;
        float handY = armY;
        float handZ = armZ + 6;

        if (player.attackTimer > 0.0f) {
            armX += fx * 7.0f;
            armY += fy * 7.0f;
            armZ += 8.0f;

            handX = armX + fx * 6.0f;
            handY = armY + fy * 6.0f;
            handZ = armZ + 8;
        }

        limbs[n++] = (Limb){
            armX, armY, armZ,
            8, 8, 16, MAT_YELLOW, false
        };

        /* Equipped tool in hand. */
        {
            uint8_t mat = MAT_BLUE;
            float tsx = 6, tsy = 6, tsz = 6;

            if (player.tool == TOOL_DRAG) {
                mat = MAT_YELLOW;
            } else if (player.tool == TOOL_DELETE) {
                mat = MAT_STONE;
                tsx = 4; tsy = 4; tsz = 12;
            } else if (player.tool == TOOL_ROCKET) {
                mat = MAT_RED;
                tsx = 6; tsy = 16; tsz = 6;
            }

            limbs[n++] = (Limb){
                handX + fx * 6.0f, handY + fy * 6.0f, handZ,
                tsx, tsy, tsz, mat, false
            };
        }
    }

    /* Head. */
    limbs[n++] = (Limb){
        bx, by, bz + 32,
        12, 8, 8, MAT_YELLOW, true
    };

    limbCount = n;
}

/* Classic smiley: two oval eyes and a curved smile. */
static void drawFace(void) {
    float fx = fastCos(player.facing);
    float fy = fastSin(player.facing);

    float toward = fx * cameraCos + fy * cameraSin;   /* -1 = facing us */

    if (toward > -0.2f)
        return;

    float lateral = -fx * cameraSin + fy * cameraCos;

    int h = lastFrontH;

    if (h < 5)
        return;

    float u = (float)h / 8.0f;

    int cx = lastFrontLeft + lastFrontW / 2 + roundFloat(lateral * (float)lastFrontW * 0.3f);

    if (lastDepth > (int)wallDepth[(cx < 0 ? 0 : (cx >= SW ? SW - 1 : cx)) >> 1])
        return;

    int top = lastFrontTop;

    int eyeW = roundFloat(u * 1.0f);
    int eyeH = roundFloat(u * 2.5f);

    if (eyeW < 1) eyeW = 1;
    if (eyeH < 2) eyeH = 2;

    int eyeY = top + roundFloat(u * 1.5f);
    int eyeOff = roundFloat(u * 2.0f);

    gfx_SetColor(UI_BLACK);

    gfx_FillRectangle(cx - eyeOff - eyeW / 2, eyeY, eyeW, eyeH);
    gfx_FillRectangle(cx + eyeOff - eyeW / 2, eyeY, eyeW, eyeH);

    int mouthY = top + roundFloat(u * 5.2f);
    int mouthHalf = roundFloat(u * 1.8f);

    if (mouthHalf < 1) mouthHalf = 1;

    gfx_HorizLine(cx - mouthHalf, mouthY, mouthHalf * 2 + 1);
    gfx_SetPixel(cx - mouthHalf - 1, mouthY - 1);
    gfx_SetPixel(cx + mouthHalf + 1, mouthY - 1);
}

/* Soft blob shadow: darkens the pixels beneath the character. */
static void drawShadow(void) {
    if (player.dead || player.cameraDistance < FIRST_PERSON_DIST)
        return;

    float gz = groundHeight(player.x, player.y, player.z);

    int sx;
    int sy;
    float depth;

    if (!project(player.x, player.y, gz, &sx, &sy, &depth))
        return;

    if (depth > 900.0f)
        return;

    float radius = 10.0f - (player.z - gz) * 0.08f;

    if (radius < 4.0f)
        radius = 4.0f;

    int rx = roundFloat(radius * PROJECTION / depth);

    if (rx < 2)
        return;

    float ratio = clampf((cameraZ - gz) / depth, 0.12f, 0.8f);

    int ry = roundFloat((float)rx * ratio);

    if (ry < 1)
        ry = 1;

    uint8_t *buffer = (uint8_t *)gfx_vbuffer;

    int depthInt = (int)depth;

    for (int dy = -ry; dy <= ry; dy++) {
        int yy = sy + dy;

        if (yy < 0 || yy >= SH)
            continue;

        float t = (float)dy / (float)ry;
        int half = (int)((float)rx * sqrtf(1.0f - t * t));

        for (int xx = sx - half; xx <= sx + half; xx++) {
            if (xx < 0 || xx >= SW)
                continue;

            int c = xx >> 1;

            if (depthInt > (int)wallDepth[c]
                && yy >= wallTop[c] && yy <= wallBottom[c]) {
                continue;
            }

            uint8_t *px = buffer + yy * SW + xx;

            *px = shadeColor(*px, 3);
        }
    }
}

/* =========================================================================
 * BUILDING TOOLS  (Roblox hopperbin style: Clone, Grab, Delete)
 * ========================================================================= */

static float snapGrid(float value) {
    return floorf(value / BUILD_GRID + 0.5f) * BUILD_GRID;
}

/*
 * Targets the closest part in front of the camera direction whose width
 * covers the aiming line.  Flat decals and very high parts (the roof) are
 * not targetable.
 */
static int findTargetPart(void) {
    int best = -1;
    float bestForward = BUILD_DISTANCE;

    float fx = fastCos(player.cameraYaw);
    float fy = fastSin(player.cameraYaw);

    for (int i = 0; i < worldPartCount; i++) {
        const WorldPart *p = &worldParts[i];

        if (!p->active || p->sz < 3.0f || p->z > 56.0f)
            continue;

        float dx = p->x - player.x;
        float dy = p->y - player.y;

        float forward = dx * fx + dy * fy;

        if (forward < 0.0f || forward > bestForward)
            continue;

        float lateral = fabsf(-dx * fy + dy * fx);
        float reach =
            0.5f * (p->sx > p->sy ? p->sx : p->sy) + 6.0f;

        if (lateral > reach)
            continue;

        bestForward = forward;
        best = i;
    }

    return best;
}

static void cloneTool(void) {
    if (hoverPart < 0)
        return;

    WorldPart src = worldParts[hoverPart];

    float rx = -fastSin(player.cameraYaw);
    float ry = fastCos(player.cameraYaw);

    float offX = 0.0f;
    float offY = 0.0f;

    /* Stack the copy beside the original along the dominant screen axis. */
    if (fabsf(rx) > fabsf(ry))
        offX = (rx > 0.0f ? 1.0f : -1.0f) * src.sx;
    else
        offY = (ry > 0.0f ? 1.0f : -1.0f) * src.sy;

    int index = addWorldPart(
        src.x + offX, src.y + offY, src.z,
        src.sx, src.sy, src.sz,
        src.material, true
    );

    if (index >= 0)
        cloneTarget = index;
}

static void deleteTool(void) {
    if (hoverPart < 0)
        return;

    worldParts[hoverPart].active = false;

    if (cloneTarget == hoverPart)
        cloneTarget = -1;

    hoverPart = -1;
}

static void grabStart(void) {
    if (hoverPart < 0)
        return;

    WorldPart *p = &worldParts[hoverPart];

    float fx = fastCos(player.cameraYaw);
    float fy = fastSin(player.cameraYaw);

    float forward = (p->x - player.x) * fx + (p->y - player.y) * fy;

    float minimum =
        0.5f * (p->sx > p->sy ? p->sx : p->sy) + PLAYER_RADIUS + 8.0f;

    heldDistance = clampf(forward, minimum, BUILD_DISTANCE);

    heldPart = hoverPart;
}

static void grabUpdate(void) {
    if (heldPart < 0 || !worldParts[heldPart].active) {
        heldPart = -1;
        return;
    }

    WorldPart *p = &worldParts[heldPart];

    float minimum =
        0.5f * (p->sx > p->sy ? p->sx : p->sy) + PLAYER_RADIUS + 8.0f;

    float distance = heldDistance < minimum ? minimum : heldDistance;

    p->x = snapGrid(player.x + fastCos(player.cameraYaw) * distance);
    p->y = snapGrid(player.y + fastSin(player.cameraYaw) * distance);
}

static void fireRocket(void) {
    if (rocket.active)
        return;

    rocket.active = true;

    rocket.dx = fastCos(player.cameraYaw);
    rocket.dy = fastSin(player.cameraYaw);

    rocket.x = player.x + rocket.dx * 14.0f;
    rocket.y = player.y + rocket.dy * 14.0f;
    rocket.z = player.z + 26.0f;

    rocket.lifetime = 3.0f;
}

/* =========================================================================
 * DEATH / RESPAWN
 * ========================================================================= */

static void spawnPlayer(void) {
    player.x = SPAWN_X;
    player.y = SPAWN_Y;
    player.z = 0.0f;
    player.vz = 0.0f;

    player.facing = -PI_F / 2.0f;
    player.cameraYaw = -PI_F / 2.0f;
    player.cameraDistance = player.cameraMaximum;

    player.walkPhase = 0.0f;
    player.walkAmount = 0.0f;
    player.attackTimer = 0.0f;

    player.health = MAX_HEALTH;
    player.respawnTimer = 0.0f;

    player.onGround = true;
    player.dead = false;

    heldPart = -1;
    cloneTarget = -1;
    hoverPart = -1;

    rocket.active = false;
    explosion.lifetime = 0.0f;
    debrisCount = 0;

    cameraZ = EYE_HEIGHT;
}

/* Humanoid died: the body breaks apart into its parts. */
static void killPlayer(void) {
    if (player.dead)
        return;

    buildLimbs();

    player.dead = true;
    player.health = 0.0f;
    player.respawnTimer = RESPAWN_TIME;

    heldPart = -1;

    debrisCount = 0;

    for (int i = 0; i < limbCount && debrisCount < MAX_DEBRIS; i++) {
        Debris *d = &debris[debrisCount];

        d->x = limbs[i].x;
        d->y = limbs[i].y;
        d->z = limbs[i].z + limbs[i].sz * 0.5f;

        uint32_t h = hash2(i, (int)(player.x + player.y));

        d->vx = ((float)(h & 255) / 255.0f - 0.5f) * 160.0f;
        d->vy = ((float)((h >> 8) & 255) / 255.0f - 0.5f) * 160.0f;
        d->vz = 120.0f + (float)((h >> 16) & 127);

        d->size = 7.0f;
        d->material = limbs[i].material;

        debrisCount++;
    }
}

static void damagePlayer(float amount) {
    if (player.dead)
        return;

    player.health -= amount;

    if (player.health <= 0.0f)
        killPlayer();
}

static void explode(float x, float y, float z) {
    explosion.x = x;
    explosion.y = y;
    explosion.z = z;
    explosion.lifetime = EXPLOSION_TIME;

    rocket.active = false;

    if (!player.dead) {
        float dx = player.x - x;
        float dy = player.y - y;
        float dz = (player.z + BODY_HEIGHT * 0.5f) - z;

        if (dx * dx + dy * dy + dz * dz
            < EXPLOSION_RADIUS * EXPLOSION_RADIUS) {
            damagePlayer(EXPLOSION_DAMAGE);
        }
    }
}

/* =========================================================================
 * SCENE (depth-sorted objects)
 * ========================================================================= */

typedef struct {
    int16_t depth;
    int16_t id;
} DrawItem;

#define ID_LIMB       200
#define ID_DEBRIS     220
#define ID_ROCKET     240
#define ID_EXPLOSION  241

static DrawItem drawList[MAX_DRAW_ITEMS];

static void drawExplosion(void) {
    int sx;
    int sy;
    float depth;

    if (!project(explosion.x, explosion.y, explosion.z, &sx, &sy, &depth))
        return;

    int col = sx < 0 ? 0 : (sx >= SW ? SW - 1 : sx);

    if ((int)depth > (int)wallDepth[col >> 1])
        return;

    float progress = 1.0f - explosion.lifetime / EXPLOSION_TIME;

    int radius = roundFloat(
        (EXPLOSION_RADIUS * (0.4f + 0.6f * progress)) * PROJECTION / depth
    );

    if (radius > 70) radius = 70;
    if (radius < 2) radius = 2;

    gfx_SetColor(UI_ORANGE);
    gfx_FillCircle(sx, sy, radius);

    gfx_SetColor(UI_FIRE);
    gfx_FillCircle(sx, sy, radius * 2 / 3);

    gfx_SetColor(UI_WHITE);
    gfx_FillCircle(sx, sy, radius / 3);
}

static void drawScene(void) {
    bool showBody =
        !player.dead && player.cameraDistance >= FIRST_PERSON_DIST;

    if (showBody)
        buildLimbs();

    int n = 0;

    for (int i = 0; i < worldPartCount && n < MAX_DRAW_ITEMS; i++) {
        const WorldPart *p = &worldParts[i];

        if (!p->active)
            continue;

        float depth =
            (p->x - cameraX) * cameraCos + (p->y - cameraY) * cameraSin;

        if (depth < -300.0f || depth > MAX_DRAW_DISTANCE + 300.0f)
            continue;

        drawList[n].depth = (int16_t)depth;
        drawList[n].id = (int16_t)i;
        n++;
    }

    if (showBody) {
        for (int i = 0; i < limbCount && n < MAX_DRAW_ITEMS; i++) {
            float depth =
                (limbs[i].x - cameraX) * cameraCos
                + (limbs[i].y - cameraY) * cameraSin;

            drawList[n].depth = (int16_t)depth;
            drawList[n].id = (int16_t)(ID_LIMB + i);
            n++;
        }
    }

    for (int i = 0; i < debrisCount && n < MAX_DRAW_ITEMS; i++) {
        float depth =
            (debris[i].x - cameraX) * cameraCos
            + (debris[i].y - cameraY) * cameraSin;

        drawList[n].depth = (int16_t)depth;
        drawList[n].id = (int16_t)(ID_DEBRIS + i);
        n++;
    }

    if (rocket.active && n < MAX_DRAW_ITEMS) {
        float depth =
            (rocket.x - cameraX) * cameraCos
            + (rocket.y - cameraY) * cameraSin;

        drawList[n].depth = (int16_t)depth;
        drawList[n].id = ID_ROCKET;
        n++;
    }

    if (explosion.lifetime > 0.0f && n < MAX_DRAW_ITEMS) {
        float depth =
            (explosion.x - cameraX) * cameraCos
            + (explosion.y - cameraY) * cameraSin;

        drawList[n].depth = (int16_t)depth;
        drawList[n].id = ID_EXPLOSION;
        n++;
    }

    /* Painter's algorithm: insertion sort, farthest first. */

    for (int i = 1; i < n; i++) {
        DrawItem key = drawList[i];
        int j = i - 1;

        while (j >= 0 && drawList[j].depth < key.depth) {
            drawList[j + 1] = drawList[j];
            j--;
        }

        drawList[j + 1] = key;
    }

    drawShadow();

    bool toolTargets =
        player.tool == TOOL_COPY
        || player.tool == TOOL_DRAG
        || player.tool == TOOL_DELETE;

    for (int k = 0; k < n; k++) {
        int id = drawList[k].id;

        if (id < MAX_WORLD_PARTS) {
            const WorldPart *p = &worldParts[id];

            bool visible = drawBox(
                p->x, p->y, p->z,
                p->sx, p->sy, p->sz,
                1.0f, 0.0f,
                p->material, true
            );

            if (visible && toolTargets
                && (id == hoverPart || id == heldPart)) {
                drawSelectionOutline();
            }
        }
        else if (id < ID_DEBRIS) {
            const Limb *l = &limbs[id - ID_LIMB];

            bool visible = drawBox(
                l->x, l->y, l->z,
                l->sx, l->sy, l->sz,
                bodyRightX, bodyRightY,
                l->material, false
            );

            if (visible && l->isHead)
                drawFace();
        }
        else if (id < ID_ROCKET) {
            const Debris *d = &debris[id - ID_DEBRIS];

            drawBox(
                d->x, d->y, d->z - d->size * 0.5f,
                d->size, d->size, d->size,
                1.0f, 0.0f,
                d->material, false
            );
        }
        else if (id == ID_ROCKET) {
            drawBox(
                rocket.x, rocket.y, rocket.z - 2.0f,
                4, 12, 4,
                -rocket.dy, rocket.dx,
                MAT_RED, false
            );
        }
        else {
            drawExplosion();
        }
    }
}

/* =========================================================================
 * HUD
 * ========================================================================= */

static void drawToolIcon(int tool, int x, int y) {
    if (tool == TOOL_COPY) {
        gfx_SetColor(PIXEL(MAT_BLUE, 12));
        gfx_FillRectangle(x + 20, y + 11, 12, 10);

        gfx_SetColor(PIXEL(MAT_BLUE, 14));
        gfx_FillRectangle(x + 26, y + 6, 12, 10);
    }
    else if (tool == TOOL_DRAG) {
        gfx_SetColor(PIXEL(MAT_YELLOW, 12));
        gfx_FillRectangle(x + 20, y + 8, 20, 12);

        gfx_SetColor(PIXEL(MAT_YELLOW, 7));
        gfx_Rectangle(x + 20, y + 8, 20, 12);
    }
    else if (tool == TOOL_DELETE) {
        gfx_SetColor(PIXEL(MAT_STONE, 12));
        gfx_FillRectangle(x + 20, y + 6, 18, 8);

        gfx_SetColor(PIXEL(MAT_WOOD, 10));
        gfx_FillRectangle(x + 27, y + 14, 4, 10);
    }
    else {
        gfx_SetColor(PIXEL(MAT_RED, 12));
        gfx_FillRectangle(x + 16, y + 11, 26, 8);

        gfx_SetColor(PIXEL(MAT_SILVER, 12));
        gfx_FillRectangle(x + 42, y + 12, 3, 6);
    }
}

static void drawHUD(void) {
    /* Place title and FPS (top left). */

    gfx_SetColor(UI_DARK);
    gfx_FillRectangle(4, 4, 138, 22);

    gfx_SetColor(UI_GRAY);
    gfx_Rectangle(4, 4, 138, 22);

    gfx_SetTextFGColor(UI_WHITE);

    gfx_PrintStringXY("Happy Home", 9, 8);

    gfx_PrintStringXY("FPS", 98, 8);
    gfx_SetTextXY(122, 8);
    gfx_PrintInt(displayedFPS, 2);

    /* Health bar (top right, classic green -> yellow -> red). */

    gfx_PrintStringXY("Health", 212, 4);

    gfx_SetColor(UI_DARK);
    gfx_FillRectangle(212, 14, 102, 12);

    gfx_SetColor(UI_GRAY);
    gfx_Rectangle(212, 14, 102, 12);

    int hp = roundFloat(player.health);

    if (hp < 0) hp = 0;
    if (hp > 100) hp = 100;

    if (hp > 0) {
        gfx_SetColor(hp > 50 ? UI_GREEN : hp > 25 ? UI_YELLOW : UI_RED);
        gfx_FillRectangle(213, 15, hp, 10);
    }

    /* Hopperbin toolbar. */

    static const char *toolNames[4] = { "Clone", "Grab", "Delete", "Rocket" };

    for (int i = 0; i < 4; i++) {
        int x = 34 + i * 64;
        int y = 196;

        gfx_SetColor(UI_DARK);
        gfx_FillRectangle(x, y, 60, 40);

        gfx_SetColor(i == (int)player.tool ? UI_YELLOW : UI_GRAY);
        gfx_Rectangle(x, y, 60, 40);

        gfx_SetTextFGColor(UI_WHITE);

        char number[2] = { (char)('1' + i), '\0' };

        gfx_PrintStringXY(number, x + 4, y + 4);

        drawToolIcon(i, x, y + 2);

        int w = (int)gfx_GetStringWidth(toolNames[i]);

        gfx_PrintStringXY(toolNames[i], x + (60 - w) / 2, y + 29);
    }

    if (player.dead) {
        gfx_SetTextFGColor(UI_WHITE);

        int w = (int)gfx_GetStringWidth("You died");

        gfx_SetColor(UI_DARK);
        gfx_FillRectangle(SW / 2 - w / 2 - 6, 110, w + 12, 18);

        gfx_PrintStringXY("You died", SW / 2 - w / 2, 115);
    }
}

/* =========================================================================
 * UPDATE
 * ========================================================================= */

static bool actionPrevious = false;
static bool resetPrevious = false;

static void selectTool(Tool tool) {
    if (player.tool == tool)
        return;

    player.tool = tool;

    heldPart = -1;
    cloneTarget = -1;
}

static void updateProjectiles(float dt) {
    if (rocket.active) {
        float travel = ROCKET_SPEED * dt;

        int steps = (int)(travel / 6.0f) + 1;

        if (steps > 8)
            steps = 8;

        float stepDist = travel / (float)steps;

        for (int i = 0; i < steps && rocket.active; i++) {
            rocket.x += rocket.dx * stepDist;
            rocket.y += rocket.dy * stepDist;

            if (tileAt(rocket.x, rocket.y) != TILE_EMPTY
                || rocketHitsPart(rocket.x, rocket.y, rocket.z)) {
                explode(rocket.x, rocket.y, rocket.z);
            }
        }

        if (rocket.active) {
            rocket.lifetime -= dt;

            if (rocket.lifetime <= 0.0f)
                explode(rocket.x, rocket.y, rocket.z);
        }
    }

    if (explosion.lifetime > 0.0f) {
        explosion.lifetime -= dt;

        if (explosion.lifetime < 0.0f)
            explosion.lifetime = 0.0f;
    }

    for (int i = 0; i < debrisCount; i++) {
        Debris *d = &debris[i];

        d->vz -= GRAVITY * dt;

        d->x += d->vx * dt;
        d->y += d->vy * dt;
        d->z += d->vz * dt;

        if (d->z < d->size * 0.5f) {
            d->z = d->size * 0.5f;
            d->vz = 0.0f;
            d->vx *= 0.8f;
            d->vy *= 0.8f;
        }
    }
}

static void update(float dt) {
    cloudDrift = wrapAngle(cloudDrift + 0.02f * dt);

    /* ---- Camera rotation and zoom ---- */

    float turn = 0.0f;

    if (kb_IsDown(kb_KeyLeft))
        turn -= 1.0f;

    if (kb_IsDown(kb_KeyRight))
        turn += 1.0f;

    player.cameraYaw = wrapAngle(player.cameraYaw + turn * 2.5f * dt);

    if (kb_IsDown(kb_KeyAdd))
        player.cameraMaximum += 120.0f * dt;

    if (kb_IsDown(kb_KeySub))
        player.cameraMaximum -= 120.0f * dt;

    player.cameraMaximum = clampf(player.cameraMaximum, 0.0f, 200.0f);

    float cv = fastCos(player.cameraYaw);
    float sv = fastSin(player.cameraYaw);

    /* ---- Reset character (Del) ---- */

    bool reset = kb_IsDown(kb_KeyDel);

    if (reset && !resetPrevious && !player.dead)
        killPlayer();

    resetPrevious = reset;

    bool action = kb_IsDown(kb_Key2nd) || kb_IsDown(kb_KeyMode);
    bool pressed = action && !actionPrevious;

    actionPrevious = action;

    if (player.dead) {
        player.respawnTimer -= dt;

        if (player.respawnTimer <= 0.0f)
            spawnPlayer();
    } else {
        /* ---- Tool selection ---- */

        if (kb_IsDown(kb_Key1)) selectTool(TOOL_COPY);
        if (kb_IsDown(kb_Key2)) selectTool(TOOL_DRAG);
        if (kb_IsDown(kb_Key3)) selectTool(TOOL_DELETE);
        if (kb_IsDown(kb_Key4)) selectTool(TOOL_ROCKET);

        /* ---- Movement ---- */

        float forward = 0.0f;
        float strafe = 0.0f;

        if (kb_IsDown(kb_KeyUp))
            forward += 1.0f;

        if (kb_IsDown(kb_KeyDown))
            forward -= 1.0f;

        if (kb_IsDown(kb_KeyApps))
            strafe += 1.0f;

        if (kb_IsDown(kb_KeyMath))
            strafe -= 1.0f;

        float moveX = cv * forward - sv * strafe;
        float moveY = sv * forward + cv * strafe;

        float length = sqrtf(moveX * moveX + moveY * moveY);

        bool moving = length > 0.01f;

        if (moving) {
            moveX /= length;
            moveY /= length;

            float remaining = WALK_SPEED * dt;

            int steps = (int)(remaining / 4.0f) + 1;

            if (steps > 8)
                steps = 8;

            float stepX = moveX * remaining / (float)steps;
            float stepY = moveY * remaining / (float)steps;

            /*
             * If something was placed on top of the player they may be
             * inside a part; let them walk out instead of being trapped.
             */
            bool stuck = partBlocks(player.x, player.y, player.z,
                                    PLAYER_RADIUS);

            for (int i = 0; i < steps; i++) {
                float nx = player.x + stepX;

                if (!solidBox(nx, player.y, PLAYER_RADIUS)
                    && (stuck || !partBlocks(nx, player.y, player.z,
                                             PLAYER_RADIUS))) {
                    player.x = nx;
                }

                float ny = player.y + stepY;

                if (!solidBox(player.x, ny, PLAYER_RADIUS)
                    && (stuck || !partBlocks(player.x, ny, player.z,
                                             PLAYER_RADIUS))) {
                    player.y = ny;
                }
            }

            float targetFacing = atan2f(moveY, moveX);

            float difference = wrapAngle(targetFacing - player.facing);

            float maxTurn = 10.0f * dt;

            difference = clampf(difference, -maxTurn, maxTurn);

            player.facing = wrapAngle(player.facing + difference);

            player.walkPhase =
                wrapAngle(player.walkPhase + 12.0f * dt);
        }

        float targetWalk = moving ? 1.0f : 0.0f;

        player.walkAmount +=
            (targetWalk - player.walkAmount)
            * clampf(12.0f * dt, 0.0f, 1.0f);

        if (!moving && player.walkAmount < 0.02f) {
            player.walkAmount = 0.0f;
            player.walkPhase = 0.0f;
        }

        if (moving || turn != 0.0f)
            cloneTarget = -1;

        /* ---- Jump and gravity ---- */

        if (kb_IsDown(kb_KeyAlpha) && player.onGround) {
            player.vz = JUMP_VELOCITY;
            player.onGround = false;
        }

        player.vz -= GRAVITY * dt;

        {
            float nz = player.z + player.vz * dt;
            float floorZ = groundHeight(player.x, player.y, player.z);

            if (nz <= floorZ) {
                nz = floorZ;
                player.vz = 0.0f;
                player.onGround = true;
            } else {
                player.onGround = false;
            }

            player.z = nz;
        }

        /* ---- Health regeneration ---- */

        if (player.health < MAX_HEALTH) {
            player.health += HEALTH_REGEN * dt;

            if (player.health > MAX_HEALTH)
                player.health = MAX_HEALTH;
        }

        /* ---- Tools ---- */

        if (player.attackTimer > 0.0f) {
            player.attackTimer -= dt;

            if (player.attackTimer < 0.0f)
                player.attackTimer = 0.0f;
        }

        if (player.tool != TOOL_ROCKET && heldPart < 0) {
            if (cloneTarget >= 0 && worldParts[cloneTarget].active)
                hoverPart = cloneTarget;
            else
                hoverPart = findTargetPart();
        }

        if (player.tool == TOOL_DRAG) {
            if (action) {
                if (heldPart < 0 && pressed)
                    grabStart();

                grabUpdate();
            } else {
                heldPart = -1;
            }
        }
        else if (pressed && player.attackTimer <= 0.0f) {
            if (player.tool == TOOL_COPY) {
                cloneTool();
                player.attackTimer = 0.2f;
            }
            else if (player.tool == TOOL_DELETE) {
                deleteTool();
                player.attackTimer = 0.2f;
            }
            else if (player.tool == TOOL_ROCKET) {
                fireRocket();
                player.attackTimer = 0.8f;
            }
        }
    }

    updateProjectiles(dt);

    /* ---- Camera: collision, zoom and vertical follow ---- */

    float desired = player.cameraMaximum;

    for (float d = 8.0f; d < player.cameraMaximum; d += 4.0f) {
        float px = player.x - cv * d;
        float py = player.y - sv * d;

        if (solidBox(px, py, 6.0f)) {
            desired = d - 4.0f;
            break;
        }
    }

    desired = clampf(desired, 0.0f, player.cameraMaximum);

    if (desired < player.cameraDistance) {
        player.cameraDistance = desired;
    } else {
        float blend = clampf(10.0f * dt, 0.0f, 1.0f);

        player.cameraDistance +=
            (desired - player.cameraDistance) * blend;
    }

    {
        float targetZ = EYE_HEIGHT + player.z;

        cameraZ += (targetZ - cameraZ) * clampf(8.0f * dt, 0.0f, 1.0f);
    }
}

/* =========================================================================
 * RENDER
 * ========================================================================= */

static void render(void) {
    cameraCos = fastCos(player.cameraYaw);
    cameraSin = fastSin(player.cameraYaw);

    cameraX = player.x - cameraCos * player.cameraDistance;
    cameraY = player.y - cameraSin * player.cameraDistance;

    drawSky();
    drawSkyObjects();
    drawFloor();
    drawWalls();
    drawScene();
    drawHUD();
}

/* =========================================================================
 * MAIN
 * ========================================================================= */

int main(void) {
    gfx_Begin();
    gfx_SetDrawBuffer();

    gfx_SetTextScale(1, 1);
    gfx_SetTextTransparentColor(255);
    gfx_SetTextBGColor(255);

    initMath();
    initPalette();
    buildTextures();
    buildMap();
    buildDecorations();

    player.cameraMaximum = 110.0f;
    player.tool = TOOL_COPY;

    spawnPlayer();

    /* Timer 1 at 32768 Hz, free running. */

    timer_Set(1, 0);
    timer_Enable(1, TIMER_32K, TIMER_NOINT, TIMER_UP);

    float fpsAccumulator = 0.0f;
    int fpsFrames = 0;

    while (!kb_IsDown(kb_KeyClear)) {
        kb_Scan();

        uint32_t ticks = timer_Get(1);

        timer_Set(1, 0);

        float dt = (float)ticks / 32768.0f;

        dt = clampf(dt, 0.001f, 0.05f);

        fpsAccumulator += dt;
        fpsFrames++;

        if (fpsAccumulator >= 0.5f) {
            displayedFPS =
                (int)((float)fpsFrames / fpsAccumulator + 0.5f);

            fpsAccumulator = 0.0f;
            fpsFrames = 0;
        }

        update(dt);
        render();

        gfx_SwapDraw();
    }

    gfx_End();

    return 0;
}
