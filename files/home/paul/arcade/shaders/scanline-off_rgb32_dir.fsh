// Sharp-bilinear + scanlines, in one pass.
//
// Replaces the -effect PNG overlay, which cannot be used here: MAME disables
// GLSL unless prescale is 1, and the overlay needs prescale >= 2 to give one
// scanline per source line. Doing both in the shader removes that conflict
// and, unlike the overlay, survives integer scaling.
//
// Two jobs:
//  1. Sharp bilinear. Plain nearest forces every source row to occupy a whole
//     number of screen rows; at 960/224 = 4.286 that means 64 rows take 5px
//     and 160 take 4px, and the assignment shifts as the image scrolls --
//     the shimmer. Here we snap to texel centres and blend across exactly one
//     screen pixel at the boundary, so pixels stay crisp but nothing snaps.
//  2. Scanlines phase-locked to the SOURCE grid, so one dark band per emulated
//     line and no crawl.

uniform sampler2D color_texture;
uniform vec2      color_texture_sz;       // source size in texels
uniform vec2      color_texture_pow2_sz;  // allocated texture size

// --- scanline tuning -------------------------------------------------------
// SCAN_DARK is the brightness of the dark band: 1.0 is off, lower is stronger.
// SCAN_DUTY is how much of each source line is dark.
//
// Do NOT copy values from the -effect PNGs. Those looked far weaker than
// their numbers suggested because the overlay path smeared them through a
// 2.14x bilinear upscale, blending every dark row into its bright neighbours.
// This shader draws the bands crisply at output resolution, so 0.25 here was
// genuinely 75% darkening and much too heavy.
//
//   0.80  barely there
//   0.65  moderate            <- current
//   0.45  strong
//   0.25  matches the old PNG's nominal value; too much in practice
//
// Thinning the band is the gentler knob if it is still too heavy -- drop
// SCAN_DUTY to 0.4 or 0.35 before darkening further, since that keeps the
// overall picture brighter.
const float SCAN_DARK = 1.00;
const float SCAN_DUTY = 0.60;
// SCAN_BLOOM: how far the bands fade out in bright areas.
//   0.0  uniform multiply -- stripes hardest on flat bright fields (wrong)
//   1.0  bands vanish completely at full white, like a real beam
const float SCAN_BLOOM = 0.00;

void main()
{
	// Fall back rather than render black if a uniform is not populated.
	vec2 tsz = color_texture_pow2_sz;
	if (tsz.x < 1.0 || tsz.y < 1.0)
		tsz = vec2(256.0, 256.0);

	vec2 uv     = gl_TexCoord[0].st;
	vec2 texels = uv * tsz;

	// --- sharp bilinear ---
	// Return the pure texel colour across most of the texel and confine the
	// blend to exactly one screen pixel at the seam.
	//
	// The earlier version had this backwards:
	//     sharp = centre + clamp(delta * scale, -0.5, 0.5);
	// which clamps the SCALED offset, so it blends across nearly the whole
	// texel and only gives a clean colour dead-centre -- a mildly sharpened
	// bilinear. That is what squashed the small text: each source row was
	// smeared into its neighbours, so strokes in 7px-tall glyphs came out at
	// visibly different thicknesses. The fix is to subtract the clamped
	// region rather than clamp the scaled value.
	vec2 scale  = 1.0 / max(fwidth(texels), vec2(1e-6));   // screen px per texel
	vec2 region = vec2(0.5) - 0.5 / scale;                 // flat zone, in texels
	vec2 centre = floor(texels) + 0.5;
	vec2 delta  = texels - centre;
	vec2 sharp  = centre + (delta - clamp(delta, -region, region)) * scale;
	vec4 col    = texture2D(color_texture, sharp / tsz);

	// --- scanlines, one per source line ---
	// A raised cosine, NOT a hard step. The pattern repeats every 4.29 screen
	// pixels here, which is not a whole number, so a square wave lands
	// differently against the pixel grid on every cycle -- some bands sit on
	// one pixel and go crisp, others straddle two and split.
	float wave = pow(0.5 - 0.5 * cos(texels.y * 6.2831853), SCAN_DUTY);

	// Bloom compensation -- the important part on this game. A real CRT beam
	// spreads as it gets brighter and fills its own gap, so scanlines are
	// WEAKEST in bright areas. A plain multiply does the opposite: it puts
	// maximum contrast on the brightest pixels. Swimmer is mostly large flat
	// fields of saturated blue and green, so a uniform multiply striped hard
	// across exactly the areas with no detail to hide the banding -- which is
	// why every strength setting looked wrong. Fading the depth out with
	// luminance keeps the flat bright areas clean and leaves the scanlines in
	// the darker, busier parts where they read as texture.
	// (This is also why mk2 never had the problem -- it is dark and detailed.)
	// Bloom is applied PER CHANNEL, not from luminance. On a CRT each phosphor
	// blooms according to its own drive level, so a hard-driven blue subpixel
	// fills its own gap whatever red and green are doing.
	//
	// Using Rec.601 luma here was measurably wrong on this game. Swimmer's
	// water is (0,128,224): luma 0.39 but value 0.88. Luma weights blue at
	// only 0.114, so the shader classed those big vivid blue fields as SHADOW
	// and gave them near-full depth -- 22% where it should have been 7%.
	// Measured off a photo of the cabinet: 12% peak-to-peak modulation on a
	// flat field that should have been about 4%.
	vec3 depth = vec3(1.0 - SCAN_DARK) * (1.0 - SCAN_BLOOM * col.rgb);
	col.rgb *= 1.0 - depth * (1.0 - wave);

	gl_FragColor = col;
}
