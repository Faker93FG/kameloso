module kameloso.main;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;

import std.concurrency;
import std.datetime : SysTime;
import std.stdio;
import std.typecons : Flag, No, Yes;


void main(string[] args)
{
    IRCBot bot;
    // Print the current settings to show what's going on.
    printObjects(bot, bot.server, settings);
}
