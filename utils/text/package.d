﻿/**
 * Utility code related to string and text processing.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.text;

import std.algorithm;
import std.ascii;
import std.exception;
import std.conv;
import std.format;
import std.string;
import std.traits;
import std.typetuple;

import core.stdc.string;

import ae.utils.array;
import ae.utils.meta;
import ae.utils.textout;

public import ae.utils.regex;

alias indexOf = std.string.indexOf;

public import ae.utils.text.ascii : ascii, DecimalSize, toDec, toDecFixed;

// ************************************************************************

/// Convenience helper
bool contains(T, U)(T[] str, U[] what)
	if (is(Unqual!T == Unqual!U))
{
	return str.indexOf(what)>=0;
}

/// CTFE helper
string formatAs(T)(auto ref T obj, string fmt)
{
	return format(fmt, obj);
}

/// Consume a LF or CRLF terminated line from s.
/// Sets s to null and returns the remainder
/// if there is no line terminator in s.
T[] eatLine(T)(ref T[] s, bool eatIncompleteLines = true)
{
	return s.skipUntil([T('\n')], eatIncompleteLines).chomp();
}

deprecated template eatLine(OnEof onEof)
{
	T[] eatLine(T)(ref T[] s)
	{
		return s.eatUntil!onEof([T('\n')]).chomp();
	}
}

unittest
{
	string s = "Hello\nworld";
	assert(s.eatLine() == "Hello");
	assert(s.eatLine() == "world");
	assert(s is null);
	assert(s.eatLine() is null);
}

// Uses memchr (not Boyer-Moore), best for short strings.
T[] fastReplace(T)(T[] what, T[] from, T[] to)
	if (T.sizeof == 1) // TODO (uses memchr)
{
	alias Unqual!T U;

//	debug scope(failure) std.stdio.writeln("fastReplace crashed: ", [what, from, to]);
	enum RAM = cast(U*)null;

	if (what.length < from.length || from.length==0)
		return what;

	if (from.length==1)
	{
		auto fromc = from[0];
		if (to.length==1)
		{
			auto p = cast(T*)memchr(what.ptr, fromc, what.length);
			if (!p)
				return what;

			auto result = what.dup;
			auto delta = result.ptr - what.ptr;
			auto toChar = to[0];
			auto end = what.ptr + what.length;
			do
			{
				(cast(U*)p)[delta] = toChar; // zomg hax lol
				p++;
				p = cast(T*)memchr(p, fromc, end - p);
			} while (p);
			return result;
		}
		else
		{
			auto p = cast(immutable(T)*)memchr(what.ptr, fromc, what.length);
			if (!p)
				return what;

			auto sb = StringBuilder(what.length);
			do
			{
				sb.put(what[0..p-what.ptr], to);
				what = what[p-what.ptr+1..$];
				p = cast(immutable(T)*)memchr(what.ptr, fromc, what.length);
			}
			while (p);

			sb.put(what);
			return sb.get();
		}
	}

	auto head = from[0];
	auto tail = from[1..$];

	auto p = cast(T*)what.ptr;
	auto end = p + what.length - tail.length;
	p = cast(T*)memchr(p, head, end-p);
	while (p)
	{
		p++;
		if (p[0..tail.length] == tail)
		{
			if (from.length == to.length)
			{
				auto result = what.dup;
				auto deltaMinusOne = (result.ptr - what.ptr) - 1;

				goto replaceA;
			dummyA: // compiler complains

				do
				{
					p++;
					if (p[0..tail.length] == tail)
					{
					replaceA:
						(cast(U*)p+deltaMinusOne)[0..to.length] = to[];
					}
					p = cast(T*)memchr(p, head, end-p);
				}
				while (p);

				return result;
			}
			else
			{
				auto start = cast(T*)what.ptr;
				auto sb = StringBuilder(what.length);
				goto replaceB;
			dummyB: // compiler complains

				do
				{
					p++;
					if (p[0..tail.length] == tail)
					{
					replaceB:
						sb.put(RAM[cast(size_t)start .. cast(size_t)p-1], to);
						start = p + tail.length;
						what = what[start-what.ptr..$];
					}
					else
					{
						what = what[p-what.ptr..$];
					}
					p = cast(T*)memchr(what.ptr, head, what.length);
				}
				while (p);

				//sb.put(what);
				sb.put(RAM[cast(size_t)start..cast(size_t)(what.ptr+what.length)]);
				return sb.get();
			}

			assert(0);
		}
		p = cast(T*)memchr(p, head, end-p);
	}

	return what;
}

unittest
{
	import std.array;
	void test(string haystack, string from, string to)
	{
		auto description = `("` ~ haystack ~ `", "` ~ from ~ `", "` ~ to ~ `")`;

		auto r1 = fastReplace(haystack, from, to);
		auto r2 =     replace(haystack, from, to);
		assert(r1 == r2, `Bad replace: ` ~ description ~ ` == "` ~ r1 ~ `"`);

		if (r1 == haystack)
			assert(r1 is haystack, `Pointless reallocation: ` ~ description);
	}

	test("Mary had a little lamb", "a", "b");
	test("Mary had a little lamb", "a", "aaa");
	test("Mary had a little lamb", "Mary", "Lucy");
	test("Mary had a little lamb", "Mary", "Jimmy");
	test("Mary had a little lamb", "lamb", "goat");
	test("Mary had a little lamb", "lamb", "sheep");
	test("Mary had a little lamb", " l", " x");
	test("Mary had a little lamb", " l", " xx");

	test("Mary had a little lamb", "X" , "Y" );
	test("Mary had a little lamb", "XX", "Y" );
	test("Mary had a little lamb", "X" , "YY");
	test("Mary had a little lamb", "XX", "YY");
	test("Mary had a little lamb", "aX", "Y" );
	test("Mary had a little lamb", "aX", "YY");

	test("foo", "foobar", "bar");
}

T[][] fastSplit(T, U)(T[] s, U d)
	if (is(Unqual!T == Unqual!U))
{
	if (!s.length)
		return null;

	auto p = cast(T*)memchr(s.ptr, d, s.length);
	if (!p)
		return [s];

	size_t n;
	auto end = s.ptr + s.length;
	do
	{
		n++;
		p++;
		p = cast(T*) memchr(p, d, end-p);
	}
	while (p);

	auto result = new T[][n+1];
	n = 0;
	auto start = s.ptr;
	p = cast(T*) memchr(start, d, s.length);
	do
	{
		result[n++] = start[0..p-start];
		start = ++p;
		p = cast(T*) memchr(p, d, end-p);
	}
	while (p);
	result[n] = start[0..end-start];

	return result;
}

T[][] splitAsciiLines(T)(T[] text)
	if (is(Unqual!T == char))
{
	auto lines = text.fastSplit('\n');
	foreach (ref line; lines)
		if (line.length && line[$-1]=='\r')
			line = line[0..$-1];
	return lines;
}

unittest
{
	assert(splitAsciiLines("a\nb\r\nc\r\rd\n\re\r\n\nf") == ["a", "b", "c\r\rd", "\re", "", "f"]);
	assert(splitAsciiLines(string.init) == splitLines(string.init));
}

T[] asciiStrip(T)(T[] s)
	if (is(Unqual!T == char))
{
	while (s.length && isWhite(s[0]))
		s = s[1..$];
	while (s.length && isWhite(s[$-1]))
		s = s[0..$-1];
	return s;
}

unittest
{
	string s = "Hello, world!";
	assert(asciiStrip(s) is s);
	assert(asciiStrip("\r\n\tHello ".dup) == "Hello");
}

/// Covering slice-list of s with interleaved whitespace.
T[][] segmentByWhitespace(T)(T[] s)
	if (is(Unqual!T == char))
{
	if (!s.length)
		return null;

	T[][] segments;
	bool wasWhite = isWhite(s[0]);
	size_t start = 0;
	foreach (p, char c; s)
	{
		bool isWhite = isWhite(c);
		if (isWhite != wasWhite)
			segments ~= s[start..p],
			start = p;
		wasWhite = isWhite;
	}
	segments ~= s[start..$];

	return segments;
}

T[] newlinesToSpaces(T)(T[] s)
	if (is(Unqual!T == char))
{
	auto slices = segmentByWhitespace(s);
	foreach (ref slice; slices)
		if (slice.contains("\n"))
			slice = " ";
	return slices.join();
}

ascii normalizeWhitespace(ascii s)
{
	auto slices = segmentByWhitespace(strip(s));
	foreach (i, ref slice; slices)
		if (i & 1) // odd
			slice = " ";
	return slices.join();
}

unittest
{
	assert(normalizeWhitespace(" Mary  had\ta\nlittle\r\n\tlamb") == "Mary had a little lamb");
}

string[] splitByCamelCase(string s)
{
	string[] result;
	size_t start = 0;
	foreach (i; 1..s.length+1)
		if (i == s.length
		 || (isLower(s[i-1]) && isUpper(s[i]))
		 || (i+1 < s.length && isUpper(s[i-1]) && isUpper(s[i]) && isLower(s[i+1]))
		)
		{
			result ~= s[start..i];
			start = i;
		}
	return result;
}

unittest
{
	assert(splitByCamelCase("parseIPString") == ["parse", "IP", "String"]);
	assert(splitByCamelCase("IPString") == ["IP", "String"]);
}

string camelCaseJoin(string[] arr)
{
	if (!arr.length)
		return null;
	string result = arr[0];
	foreach (s; arr[1..$])
		result ~= std.ascii.toUpper(s[0]) ~ s[1..$];
	return result;
}

unittest
{
	assert("parse-IP-string".split('-').camelCaseJoin() == "parseIPString");
}

// ************************************************************************

private __gshared char[256] asciiLower, asciiUpper;

shared static this()
{
	foreach (c; 0..256)
	{
		asciiLower[c] = cast(char)std.ascii.toLower(c);
		asciiUpper[c] = cast(char)std.ascii.toUpper(c);
	}
}

void xlat(alias TABLE, T)(T[] buf)
{
	foreach (ref c; buf)
		c = TABLE[c];
}

alias xlat!(asciiLower, char) asciiToLower;
alias xlat!(asciiUpper, char) asciiToUpper;

// ************************************************************************

/// Case-insensitive ASCII string.
alias CIAsciiString = NormalizedArray!(immutable(char), s => s.byCodeUnit.map!(std.ascii.toLower));

///
unittest
{
	CIAsciiString s = "test";
	assert(s == "TEST");
	assert(s >= "Test" && s <= "Test");
	assert(CIAsciiString("a") == CIAsciiString("A"));
	assert(CIAsciiString("a") != CIAsciiString("B"));
	assert(CIAsciiString("a") <  CIAsciiString("B"));
	assert(CIAsciiString("A") <  CIAsciiString("b"));
	assert(CIAsciiString("я") != CIAsciiString("Я"));
}

/// Case-insensitive Unicode string.
alias CIUniString = NormalizedArray!(immutable(char), s => s.map!(std.uni.toLower));

///
unittest
{
	CIUniString s = "привет";
	assert(s == "ПРИВЕТ");
	assert(s >= "Привет" && s <= "Привет");
	assert(CIUniString("я") == CIUniString("Я"));
	assert(CIUniString("а") != CIUniString("Б"));
	assert(CIUniString("а") <  CIUniString("Б"));
	assert(CIUniString("А") <  CIUniString("б"));
}

// ************************************************************************

import std.utf;

/// Convert any data to a valid UTF-8 bytestream, so D's string functions can
/// properly work on it.
string rawToUTF8(in char[] s)
{
	auto d = new dchar[s.length];
	foreach (i, char c; s)
		d[i] = c;
	return toUTF8(d);
}

/// Undo rawToUTF8.
ascii UTF8ToRaw(in char[] r) pure
{
	auto s = new char[r.length];
	size_t i = 0;
	foreach (dchar c; r)
	{
		assert(c < '\u0100');
		s[i++] = cast(char)c;
	}
	return s[0..i];
}

unittest
{
	char[1] c;
	for (int i=0; i<256; i++)
	{
		c[0] = cast(char)i;
		assert(UTF8ToRaw(rawToUTF8(c[])) == c[], format("%s -> %s -> %s", cast(ubyte[])c[], cast(ubyte[])rawToUTF8(c[]), cast(ubyte[])UTF8ToRaw(rawToUTF8(c[]))));
	}
}

/// Where a delegate with this signature is required.
string nullStringTransform(in char[] s) { return to!string(s); }

string forceValidUTF8(string s)
{
	try
	{
		validate(s);
		return s;
	}
	catch (UTFException)
		return rawToUTF8(s);
}

// ************************************************************************

/// Return the slice up to the first NUL character,
/// or of the whole array if none is found.
C[] fromZArray(C, n)(ref C[n] arr)
{
	auto p = arr.representation.countUntil(0);
	return arr[0 .. p<0 ? $ : p];
}

/// ditto
C[] fromZArray(C)(C[] arr)
{
	auto p = arr.representation.countUntil(0);
	return arr[0 .. p<0 ? $ : p];
}

unittest
{
	char[4] arr = "ab\0d";
	assert(arr.fromZArray == "ab");
	arr[] = "abcd";
	assert(arr.fromZArray == "abcd");
}

unittest
{
	string arr = "ab\0d";
	assert(arr.fromZArray == "ab");
	arr = "abcd";
	assert(arr.fromZArray == "abcd");
}

// ************************************************************************

/// Formats binary data as a hex dump (three-column layout consisting of hex
/// offset, byte values in hex, and printable low-ASCII characters).
string hexDump(const(void)[] b)
{
	auto data = cast(const(ubyte)[]) b;
	assert(data.length);
	size_t i=0;
	string s;
	while (i<data.length)
	{
		s ~= format("%08X:  ", i);
		foreach (x; 0..16)
		{
			if (i+x<data.length)
				s ~= format("%02X ", data[i+x]);
			else
				s ~= "   ";
			if (x==7)
				s ~= "| ";
		}
		s ~= "  ";
		foreach (x; 0..16)
		{
			if (i+x<data.length)
				if (data[i+x]==0)
					s ~= ' ';
				else
				if (data[i+x]<32 || data[i+x]>=128)
					s ~= '.';
				else
					s ~= cast(char)data[i+x];
			else
				s ~= ' ';
		}
		s ~= "\n";
		i += 16;
	}
	return s;
}

import std.conv;

T fromHex(T : ulong = uint, C)(const(C)[] s)
{
	T result = parse!T(s, 16);
	enforce(s.length==0, new ConvException("Could not parse entire string"));
	return result;
}

ubyte[] arrayFromHex(in char[] hex, ubyte[] buf = null)
{
	if (buf is null)
		buf = new ubyte[hex.length/2];
	else
		assert(buf.length == hex.length/2);
	for (int i=0; i<hex.length; i+=2)
		buf[i/2] = cast(ubyte)(
			hexDigits.indexOf(hex[i  ], CaseSensitive.no)*16 +
			hexDigits.indexOf(hex[i+1], CaseSensitive.no)
		);
	return buf;
}

template toHex(alias digits = hexDigits)
{
	char[] toHex(in ubyte[] data, char[] buf) pure
	{
		assert(buf.length == data.length*2);
		foreach (i, b; data)
		{
			buf[i*2  ] = digits[b>>4];
			buf[i*2+1] = digits[b&15];
		}
		return buf;
	}

	string toHex(in ubyte[] data) pure
	{
		auto buf = new char[data.length*2];
		foreach (i, b; data)
		{
			buf[i*2  ] = digits[b>>4];
			buf[i*2+1] = digits[b&15];
		}
		return buf;
	}
}

alias toLowerHex = toHex!lowerHexDigits;

void toHex(T : ulong, size_t U = T.sizeof*2)(T n, ref char[U] buf)
{
	foreach (i; Reverse!(RangeTuple!(T.sizeof*2)))
	{
		buf[i] = hexDigits[n & 0xF];
		n >>= 4;
	}
}

unittest
{
	ubyte[] bytes = [0x12, 0x34];
	assert(toHex(bytes) == "1234");
}

unittest
{
	ubyte[] bytes = [0x12, 0x34];
	char[] buf = new char[4];
	toHex(bytes, buf);
	assert(buf == "1234");
}

unittest
{
	char[8] buf;
	toHex(0x01234567, buf);
	assert(buf == "01234567");
}

/// How many significant decimal digits does a FP type have
/// (determined empirically)
enum significantDigits(T : real) = 2 + 2 * T.sizeof;

/// Format string for a FP type which includes all necessary
/// significant digits
enum fpFormatString(T) = "%." ~ text(significantDigits!T) ~ "g";

/// Get shortest string representation of a FP type that still converts to exactly the same number.
template fpToString(F)
{
	string fpToString(F v)
	{
		/// Bypass FPU register, which may contain a different precision
		static F forceType(F d) { static F n; n = d; return n; }

		StaticBuf!(char, 64) buf;
		formattedWrite(&buf, fpFormatString!F, forceType(v));
		char[] s = buf.data();

		if (s != "nan" && s != "-nan" && s != "inf" && s != "-inf")
		{
			if (forceType(to!F(s)) != v)
			{
				static if (is(F == real))
				{
					// Something funny with DM libc real parsing... e.g. 0.6885036635121051783
					return s.idup;
				}
				else
					assert(false, "Initial conversion fails: " ~ format(fpFormatString!F, to!F(s)));
			}

			foreach_reverse (i; 1..s.length)
				if (s[i]>='0' && s[i]<='8')
				{
					s[i]++;
					if (forceType(to!F(s[0..i+1]))==v)
						s = s[0..i+1];
					else
						s[i]--;
				}
			while (s.length>2 && s[$-1]!='.' && forceType(to!F(s[0..$-1]))==v)
				s = s[0..$-1];
		}
		return s.idup;
	}

	static if (!is(F == real))
	unittest
	{
		union U
		{
			ubyte[F.sizeof] bytes;
			F d;
			string toString() { return (fpFormatString!F ~ " %a [%(%02X %)]").format(d, d, bytes[]); }
		}
		import std.random : Xorshift, uniform;
		import std.stdio : stderr;
		Xorshift rng;
		foreach (n; 0..10000)
		{
			U u;
			foreach (ref b; u.bytes[])
				b = uniform!ubyte(rng);
			static if (is(F == real))
				u.bytes[7] |= 0x80; // require normalized value
			scope(failure) stderr.writeln("Input:\t", u);
			auto s = fpToString(u.d);
			scope(failure) stderr.writeln("Result:\t", s);
			if (s == "nan" || s == "-nan")
				continue; // there are many NaNs...
			U r;
			r.d = to!F(s);
			assert(r.bytes == u.bytes,
				"fpToString mismatch:\nOutput:\t%s".format(r));
		}
	}
}

alias doubleToString = fpToString!double;

unittest
{
	alias floatToString = fpToString!float;
	alias realToString = fpToString!real;
}

string numberToString(T)(T v)
	if (isNumeric!T)
{
	static if (is(T : real))
		return fpToString(v);
	else
		return toDec(v);
}

// ************************************************************************

/// Simpler implementation of Levenshtein string distance
int stringDistance(string s, string t)
{
	int n = cast(int)s.length;
	int m = cast(int)t.length;
	if (n == 0) return m;
	if (m == 0) return n;
	int[][] distance = new int[][](n+1, m+1); // matrix
	int cost=0;
	//init1
	foreach (i; 0..n+1) distance[i][0]=i;
	foreach (j; 0..m+1) distance[0][j]=j;
	//find min distance
	foreach (i; 1..n+1)
		foreach (j; 1..m+1)
		{
			cost = t[j-1] == s[i-1] ? 0 : 1;
			distance[i][j] = min(
				distance[i-1][j  ] + 1,
				distance[i  ][j-1] + 1,
				distance[i-1][j-1] + cost
			);
		}
	return distance[n][m];
}

/// Return a number between 0.0 and 1.0 indicating how similar two strings are
/// (1.0 if identical)
float stringSimilarity(string string1, string string2)
{
	float dis = stringDistance(string1, string2);
	float maxLen = string1.length;
	if (maxLen < string2.length)
		maxLen = string2.length;
	if (maxLen == 0)
		return 1;
	else
		return 1f - dis/maxLen;
}

/// Select best match from a list of items.
/// Returns -1 if none are above the threshold.
sizediff_t findBestMatch(in string[] items, string target, float threshold = 0.7)
{
	sizediff_t found = -1;
	float best = 0;

	foreach (i, item; items)
	{
		float match = stringSimilarity(toLower(item),toLower(target));
		if (match>threshold && match>=best)
		{
			best = match;
			found = i;
		}
	}

	return found;
}

/// Select best match from a list of items.
/// Returns null if none are above the threshold.
string selectBestFrom(in string[] items, string target, float threshold = 0.7)
{
	auto index = findBestMatch(items, target, threshold);
	return index < 0 ? null : items[index];
}

// ************************************************************************


string randomString(int length=20, string chars="abcdefghijklmnopqrstuvwxyz")
{
	import std.random;
	import std.range;

	return length.iota.map!(n => chars[uniform(0, $)]).array;
}
