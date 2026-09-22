// Pass-through vertex stage. MAME's GLSL path is a compatibility profile,
// so ftransform()/gl_TexCoord are the right idiom here.
void main()
{
	gl_Position    = ftransform();
	gl_FrontColor  = gl_Color;
	gl_TexCoord[0] = gl_MultiTexCoord0;
}
