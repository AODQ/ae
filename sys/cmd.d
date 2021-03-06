/**
 * Simple execution of shell commands,
 * and wrappers for common utilities.
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

module ae.sys.cmd;

import core.thread;

import std.exception;
import std.process;
import std.stdio;
import std.string;

import ae.sys.file;

string getTempFileName(string extension)
{
	import std.random;
	import std.file;
	import std.path : buildPath;

	static int counter;
	return buildPath(tempDir(), format("run-%d-%d-%d-%d.%s",
		getpid(),
		getCurrentThreadID(),
		uniform!uint(),
		counter++,
		extension
	));
}

ulong getCurrentThreadID()
{
	version (Windows)
	{
		import core.sys.windows.windows;
		return GetCurrentThreadId();
	}
	else
	version (Posix)
	{
		import core.sys.posix.pthread;
		return cast(ulong)pthread_self();
	}
}

// ************************************************************************

struct ProcessParams
{
	const(string[string]) environment = null;
	std.process.Config config = std.process.Config.none;
	size_t maxOutput = size_t.max;
	string workDir = null;

	this(Params...)(Params params)
	{
		foreach (arg; params)
		{
			static if (is(typeof(arg) == string))
				workDir = arg;
			else
			static if (is(typeof(arg) : const(string[string])))
				environment = arg;
			else
			static if (is(typeof(arg) == size_t))
				maxOutput = arg;
			else
			static if (is(typeof(arg) == std.process.Config))
				config = arg;
			else
				static assert(false, "Unknown type for process invocation parameter: " ~ typeof(arg).stringof);
		}
	}
}

private void invoke(alias runner)(string[] args)
{
	//debug scope(failure) std.stdio.writeln("[CWD] ", getcwd());
	debug(CMD) std.stdio.stderr.writeln("invoke: ", args);
	auto status = runner();
	enforce(status == 0,
		"Command `%s` failed with status %d".format(escapeShellCommand(args), status));
}

/// std.process helper.
/// Run a command, and throw if it exited with a non-zero status.
void run(Params...)(string[] args, Params params)
{
	auto parsed = ProcessParams(params);
	invoke!({ return spawnProcess(
				args, stdin, stdout, stderr,
				parsed.environment, parsed.config, parsed.workDir
			).wait(); })(args);
}

/// std.process helper.
/// Run a command and collect its output.
/// Throw if it exited with a non-zero status.
string query(Params...)(string[] args, Params params)
{
	auto parsed = ProcessParams(params);
	string output;
	invoke!({
		auto result = execute(args, parsed.environment, parsed.config, parsed.maxOutput, parsed.workDir);
		output = result.output.stripRight();
		return result.status;
	})(args);
	return output;
}

/// std.process helper.
/// Run a command, feed it the given input, and collect its output.
/// Throw if it exited with non-zero status. Return output.
T[] pipe(T, Params...)(string[] args, in T[] input, Params params)
{
	auto parsed = ProcessParams(params);
	T[] output;
	invoke!({
		auto pipes = pipeProcess(args, Redirect.stdin | Redirect.stdout,
			parsed.environment, parsed.config, parsed.workDir);
		auto f = pipes.stdin;
		auto writer = writeFileAsync(f, input);
		scope(exit) writer.join();
		output = cast(T[])readFile(pipes.stdout);
		return pipes.pid.wait();
	})(args);
	return output;
}

// ************************************************************************

ubyte[] iconv(in void[] data, string inputEncoding, string outputEncoding)
{
	auto args = ["timeout", "30", "iconv", "-f", inputEncoding, "-t", outputEncoding];
	auto result = pipe(args, data);
	return cast(ubyte[])result;
}

string iconv(in void[] data, string inputEncoding)
{
	import std.utf;
	auto result = cast(string)iconv(data, inputEncoding, "UTF-8");
	validate(result);
	return result;
}

version (HAVE_UNIX)
unittest
{
	assert(iconv("Hello"w, "UTF-16LE") == "Hello");
}

string sha1sum(in void[] data)
{
	auto output = cast(string)pipe(["sha1sum", "-b", "-"], data);
	return output[0..40];
}

version (HAVE_UNIX)
unittest
{
	assert(sha1sum("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709");
	assert(sha1sum("a  b\nc\r\nd") == "667c71ffe2ac8a4fe500e3b96435417e4c5ec13b");
}

// ************************************************************************

import ae.utils.path;
deprecated alias NULL_FILE = nullFileName;

// ************************************************************************

/// Reverse of std.process.environment.toAA
void setEnvironment(string[string] env)
{
	foreach (k, v; env)
		if (k.length)
			environment[k] = v;
	foreach (k, v; environment.toAA())
		if (k.length && k !in env)
			environment.remove(k);
}

import ae.utils.array;
import ae.utils.regex;
import std.regex;

string expandEnvVars(alias RE)(string s, string[string] env = std.process.environment.toAA)
{
	string result;
	size_t last = 0;
	foreach (c; s.matchAll(RE))
	{
		result ~= s[last..s.sliceIndex(c[1])];
		auto var = c[2];
		string value = env.get(var, c[1]);
		result ~= value;
		last = s.sliceIndex(c[1]) + c[1].length;
	}
	result ~= s[last..$];
	return result;
}

alias expandWindowsEnvVars = expandEnvVars!(re!`(%(.*?)%)`);

unittest
{
	std.process.environment[`FOOTEST`] = `bar`;
	assert("a%FOOTEST%b".expandWindowsEnvVars() == "abarb");
}

// ************************************************************************

int waitTimeout(Pid pid, Duration time)
{
	bool ok = false;
	auto t = new Thread({
		Thread.sleep(time);
		if (!ok)
			try
				pid.kill();
			catch (Exception) {} // Ignore race condition
	}).start();
	auto result = pid.wait();
	ok = true;
	return result;
}
