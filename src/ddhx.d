/**
 * Main rendering engine.
 */
module ddhx;

import std.stdio : write, writeln, writef, writefln;
import std.mmfile;
import core.stdc.stdio : printf, fflush, puts, snprintf;
import core.stdc.string : memset;
import menu, ddcon;
import utils : formatsize, unformat;

/// Copyright string
enum COPYRIGHT = "Copyright (c) dd86k 2017-2020";

/// App version
enum APP_VERSION = "0.2.0";

/// Offset type (hex, dec, etc.)
enum OffsetType : size_t {
	Hex, Decimal, Octal
}

/// 
enum DisplayMode : ubyte {
	Default, Text, Data
}

/// Default character for non-displayable characters
enum DEFAULT_CHAR = '.';

/// For header
private __gshared const char[] offsetTable = [
	'h', 'd', 'o'
];
/// For formatting
private __gshared const char[] formatTable = [
	'X', 'u', 'o'
];

//
// User settings
//

/// Bytes shown per row
__gshared ushort BytesPerRow = 16;
/// Current offset view type
__gshared OffsetType CurrentOffsetType = void;
/// Current display view type
__gshared DisplayMode CurrentDisplayMode = void;

//
// Internal
//

__gshared MmFile CFile = void;	/// Current file
__gshared ubyte* mmbuf = void;	/// mmfile buffer address
__gshared uint screenl = void;	/// screen size in bytes, 1 dimensional buffer

__gshared string fname = void;	/// filename
__gshared long fpos = void;	/// Current file position
__gshared long fsize = void;	/// File size

private __gshared char[32] tfsizebuf;	/// total formatted size buffer
private __gshared char[] tfsize;	/// total formatted size (slice)

/// Main app entry point
/// Params: pos = File position to start with
void ddhx_main(long pos) {
	import settings : HandleWidth;

	fpos = pos;
	tfsize = formatsize(tfsizebuf, fsize);
	coninit;
	ddhx_prep;
	conclear;
	ddhx_update_offsetbar;
	if (ddhx_render_raw < conheight - 2)
		ddhx_update_infobar;
	else
		ddhx_update_infobar_raw;

	InputInfo k = void;
KEY:
	coninput(k);
	switch (k.value) {

	//
	// Navigation
	//

	case Key.UpArrow, Key.K:
		if (fpos - BytesPerRow >= 0)
			ddhx_seek_unsafe(fpos - BytesPerRow);
		else
			ddhx_seek_unsafe(0);
		break;
	case Key.DownArrow, Key.J:
		if (fpos + screenl + BytesPerRow <= fsize)
			ddhx_seek_unsafe(fpos + BytesPerRow);
		else
			ddhx_seek_unsafe(fsize - screenl);
		break;
	case Key.LeftArrow, Key.H:
		if (fpos - 1 >= 0) // Else already at 0
			ddhx_seek_unsafe(fpos - 1);
		break;
	case Key.RightArrow, Key.L:
		if (fpos + screenl + 1 <= fsize)
			ddhx_seek_unsafe(fpos + 1);
		else
			ddhx_seek_unsafe(fsize - screenl);
		break;
	case Key.PageUp, Mouse.ScrollUp:
		if (fpos - cast(long)screenl >= 0)
			ddhx_seek_unsafe(fpos - screenl);
		else
			ddhx_seek_unsafe(0);
		break;
	case Key.PageDown, Mouse.ScrollDown:
		if (fpos + screenl + screenl <= fsize)
			ddhx_seek_unsafe(fpos + screenl);
		else
			ddhx_seek_unsafe(fsize - screenl);
		break;
	case Key.Home:
		ddhx_seek_unsafe(k.key.ctrl ? 0 : fpos - (fpos % BytesPerRow));
		break;
	case Key.End:
		if (k.key.ctrl) {
			ddhx_seek_unsafe(fsize - screenl);
		} else {
			const long np = fpos +
				(BytesPerRow - fpos % BytesPerRow);
			ddhx_seek_unsafe(np + screenl <= fsize ? np : fsize - screenl);
		}
		break;

	//
	// Actions/Shortcuts
	//

	case Key.Escape, Key.Enter, Key.Colon:
		hxmenu;
		break;
	case Key.G:
		hxmenu("g ");
		ddhx_update_offsetbar();
		break;
	case Key.I:
		ddhx_fileinfo;
		break;
	case Key.R, Key.F5:
		ddhx_refresh;
		break;
	case Key.A:
		HandleWidth("a");
		ddhx_refresh;
		break;
	case Key.Q: ddhx_exit; break;
	default:
	}
	goto KEY;
}

/// Refresh the entire screen
void ddhx_refresh() {
	ddhx_prep;
	conclear;
	ddhx_update_offsetbar;
	if (ddhx_render_raw < conheight - 2)
		ddhx_update_infobar;
	else
		ddhx_update_infobar_raw;
}

/**
 * Update the upper offset bar.
 */
void ddhx_update_offsetbar() {
	char [8]format = cast(char[8])" %02X"; // default
	format[4] = formatTable[CurrentOffsetType];
	conpos(0, 0);
	printf("Offset %c ", offsetTable[CurrentOffsetType]);
	for (ushort i; i < BytesPerRow; ++i)
		printf(cast(char*)format, i);
	putchar('\n');
}

/// Update the bottom current information bar.
void ddhx_update_infobar() {
	conpos(0, conheight - 1);
	ddhx_update_infobar_raw;
}

/// Updates information bar without cursor position call.
void ddhx_update_infobar_raw() {
	char[32] bl = void, cp = void;
	writef(" %*s | %*s/%*s | %7.3f%%",
		7,  formatsize(bl, screenl), // Buffer size
		10, formatsize(cp, fpos), // Formatted position
		10, tfsize, // Total file size
		((cast(float)fpos + screenl) / fsize) * 100 // Pos/filesize%
	);
}

/// Determine screensize
void ddhx_prep() {
	const int bufs = (conheight - 2) * BytesPerRow; // Proposed buffer size
	screenl = fsize >= bufs ? bufs : cast(uint)fsize;
}

/**
 * Goes to the specified position in the file.
 * Ignores bounds checking for performance reasons.
 * Sets CurrentPosition.
 * Params: pos = New position
 */
void ddhx_seek_unsafe(long pos) {
	if (screenl < fsize) {
		fpos = pos;
		if (ddhx_render < conheight - 2)
			ddhx_update_infobar;
		else
			ddhx_update_infobar_raw;
	} else
		ddhx_msglow("Navigation disabled, buffer too small");
}

/**
 * Goes to the specified position in the file.
 * Checks bounds and calls Goto.
 * Params: pos = New position
 */
void ddhx_seek(long pos) {
	if (pos + screenl > fsize)
		ddhx_seek_unsafe(fsize - screenl);
	else
		ddhx_seek_unsafe(pos);
}

/**
 * Parses the string as a long and navigates to the file location.
 * Includes offset checking (+/- notation).
 * Params: str = String as a number
 */
void ddhx_seek(string str) {
	byte rel = void; // Lazy code
	if (str[0] == '+') { // relative position
		rel = 1;
		str = str[1..$];
	} else if (str[0] == '-') {
		rel = 2;
		str = str[1..$];
	}
	long l = void;
	if (unformat(str, l) == false) {
		ddhx_msglow("Could not parse number");
		return;
	}
	switch (rel) {
	case 1:
		if (fpos + l - screenl < fsize)
			ddhx_seek_unsafe(fpos + l);
		break;
	case 2:
		if (fpos - l >= 0)
			ddhx_seek_unsafe(fpos - l);
		break;
	default:
		if (l >= 0 && l < fsize - screenl) {
			ddhx_seek_unsafe(l);
		} else {
			import std.format : format;
			ddhx_msglow(format("Range too far or negative: %d (%XH)", l, l));
		}
	}
}

/// Update display from buffer
/// Returns: See ddhx_render_raw
uint ddhx_render() {
	conpos(0, 1);
	return ddhx_render_raw;
}

/// Update display from buffer without setting cursor
/// Returns: The number of lines printed on screen
uint ddhx_render_raw() {
	__gshared char[] hexTable = [
		'0', '1', '2', '3', '4', '5', '6', '7',
		'8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
	];

	uint linesp; /// Lines printed
	char[2048] buf = void;

	size_t viewpos = cast(size_t)fpos;
	size_t viewend = viewpos + screenl; /// window length
	ubyte *filebuf = cast(ubyte*)CFile[viewpos..viewend].ptr;

	const(char) *fposfmt = void;
	with (OffsetType)
	final switch (CurrentOffsetType) {
	case Hex:	fposfmt = "%8zX "; break;
	case Octal:	fposfmt = "%8zo "; break;
	case Decimal:	fposfmt = "%8zd "; break;
	}

	// vi: view index
	for (size_t vi; vi < screenl; viewpos += BytesPerRow) {
		// Offset column: Cannot be negative since the buffer will
		// always be large enough
		size_t bufindex = snprintf(buf.ptr, 32, fposfmt, viewpos);

		// data bytes left to be treated for the row
		size_t left = screenl - vi;

		if (left >= BytesPerRow) {
			left = BytesPerRow;
		} else { // left < BytesPerRow
			memset(buf.ptr + bufindex, ' ', 2048);
		}

		// Data buffering (hexadecimal and ascii)
		// hi: hex buffer offset
		// ai: ascii buffer offset
		size_t hi = bufindex;
		size_t ai = bufindex + (BytesPerRow * 3);
		buf[ai] = ' ';
		buf[ai+1] = ' ';
		for (ai += 2; left > 0; --left, hi += 3, ++ai) {
			ubyte b = filebuf[vi++];
			buf[hi] = ' ';
			buf[hi+1] = hexTable[b >> 4];
			buf[hi+2] = hexTable[b & 15];
			buf[ai] = b > 0x7E || b < 0x20 ? DEFAULT_CHAR : b;
		}

		// null terminator
		buf[ai] = 0;

		// Output
		puts(buf.ptr);
		++linesp;
	}

	return linesp;
}

/**
 * Message once (upper bar)
 * Params: msg = Message string
 */
void ddhx_msgtop(string msg) {
	conpos(0, 0);
	writef("%s%*s", msg, (conwidth - 1) - msg.length, " ");
}

/**
 * Message once (bottom bar)
 * Params: msg = Message string
 */
void ddhx_msglow(string msg) {
	conpos(0, conheight - 1);
	writef("%s%*s", msg, (conwidth - 1) - msg.length, " ");
}

/**
 * Bottom bar message.
 * Params:
 *   f = Format
 *   arg = String argument
 */
void ddhx_msglow(string f, string arg) {
	//TODO: (string format, ...) format, remove other (string) func
	import std.format : format;
	ddhx_msglow(format(f, arg));
}

/// Print some file information at the bottom bar
void ddhx_fileinfo() {
	import std.format : sformat;
	import std.path : baseName;
	char[256] b = void;
	//TODO: Use ddhx_msglow(string fmt, ...) whenever available
	ddhx_msglow(cast(string)b.sformat!"%s  %s"(tfsize, fname.baseName));
}

/// Exits ddhx
void ddhx_exit() {
	import core.stdc.stdlib : exit;
	conclear;
	exit(0);
}
