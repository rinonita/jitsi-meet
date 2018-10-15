local get_room_from_jid = module:require "util".get_room_from_jid;
local jid_resource = require "util.jid".resource;
local ext_events = module:require "ext_events"

local muc_component_host = module:get_option_string("muc_component");
if muc_component_host == nil then
    log("error", "No muc_component specified. No muc to operate on!");
    return;
end
local muc_module = module:context("conference.damencho.jitsi.net");
if muc_module == nil then
    log("error", "No such muc found, check muc_component config.");
    return;
end

log("debug", "Starting speakerstats for %s", muc_component_host);

-- receives messages from client currently connected to the room
-- clients indicates their own dominant speaker events
function on_message(event)
    -- Check the type of the incoming stanza to avoid loops:
    if event.stanza.attr.type == "error" then
        return; -- We do not want to reply to these, so leave.
    end

    local speakerStats
        = event.stanza:get_child('speakerstats', 'http://jitsi.org/jitmeet');
    if speakerStats then
        local roomAddress = speakerStats.attr.room;
        local room = get_room_from_jid(roomAddress);

        if not room then
            log("warn", "No room found %s", roomAddress);
            return false;
        end

        local roomSpeakerStats = room.speakerStats;
        local from = event.stanza.attr.from;

        local occupant = room:get_occupant_by_real_jid(from);
        if not occupant then
            log("warn", "No occupant %s found for %s", from, roomAddress);
            return false;
        end

        local newDominantSpeaker = roomSpeakerStats[occupant.jid];
        local oldDominantSpeakerId = roomSpeakerStats['dominantSpeakerId'];

        if oldDominantSpeakerId then
            roomSpeakerStats[oldDominantSpeakerId]:setIsDominantSpeaker(false);
        end

        if newDominantSpeaker then
            newDominantSpeaker:setIsDominantSpeaker(true);
        end

        room.speakerStats['dominantSpeakerId'] = occupant.jid;
    end

    return true
end

--- Start SpeakerStats implementation
local SpeakerStats = {};
SpeakerStats.__index = SpeakerStats;

function new_SpeakerStats(nick)
    return setmetatable({
        totalDominantSpeakerTime = 0;
        _dominantSpeakerStart = nil;
        _isDominantSpeaker = false;
        nick = nick;
        displayName = nil;
    }, SpeakerStats);
end

-- Changes the dominantSpeaker data for current occupant
-- saves start time if it is new dominat speaker
-- or calculates and accumulates time of speaking
function SpeakerStats:setIsDominantSpeaker(isNowDominantSpeaker)
    log("debug",
        "set isDominant %s for %s", tostring(isNowDominantSpeaker), self.nick);

    if not self._isDominantSpeaker and isNowDominantSpeaker then
        self._dominantSpeakerStart = os.time();
    elseif self._isDominantSpeaker and not isNowDominantSpeaker then
        local now = os.time();
        local timeElapsed = now - (self._dominantSpeakerStart or 0);

        self.totalDominantSpeakerTime
            = self.totalDominantSpeakerTime + timeElapsed;
        self._dominantSpeakerStart = nil;
    end

    self._isDominantSpeaker = isNowDominantSpeaker;
end
--- End SpeakerStats

-- create speakerStats for the room
function room_created(event)
    local room = event.room;
    room.speakerStats = {};
end

-- Create SpeakerStats object for the joined user
function occupant_joined(event)
    local room = event.room;
    local occupant = event.occupant;
    local nick = jid_resource(occupant.nick);

    if room.speakerStats then
        room.speakerStats[occupant.jid] = new_SpeakerStats(nick);
    end
end

-- Occupant left set its dominant speaker to false and update the store the
-- display name
function occupant_leaving(event)
    local room = event.room;
    local occupant = event.occupant;

    local speakerStatsForOccupant = room.speakerStats[occupant.jid];
    if speakerStatsForOccupant then
        speakerStatsForOccupant:setIsDominantSpeaker(false);

        -- set display name
        local displayName = occupant:get_presence():get_child_text(
            'nick', 'http://jabber.org/protocol/nick');
        speakerStatsForOccupant.displayName = displayName;
    end
end

-- Conference ended, send speaker stats
function room_destroyed(event)
    local room = event.room;

    ext_events.speaker_stats(room, room.speakerStats);
end

module:hook("message/host", on_message);
muc_module:hook("muc-room-created", room_created, -1);
muc_module:hook("muc-occupant-joined", occupant_joined, -1);
muc_module:hook("muc-occupant-pre-leave", occupant_leaving, -1);
muc_module:hook("muc-room-destroyed", room_destroyed, -1);
