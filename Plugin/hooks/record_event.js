ObjC.import("Foundation");

var ALLOWED_FIELDS = [
    "session_id",
    "turn_id",
    "hook_event_name",
    "timestamp",
];
var SUPPORTED_EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PermissionRequest",
    "PostToolUse",
    "Stop",
];
var MAX_INPUT_BYTES = 8 * 1024 * 1024;
var MAX_FIELD_CHARACTERS = 16 * 1024;
var MAX_IDENTIFIER_CHARACTERS = 256;
var IDENTIFIER_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;

function isSafeIdentifier(value) {
    return (
        typeof value === "string" &&
        value.length > 0 &&
        value.length <= MAX_IDENTIFIER_CHARACTERS &&
        IDENTIFIER_PATTERN.test(value)
    );
}

function readBoundedStandardInput() {
    var handle = $.NSFileHandle.fileHandleWithStandardInput;
    var collected = $.NSMutableData.data;
    var totalBytes = 0;
    var oversized = false;

    while (true) {
        var chunk = handle.readDataOfLength(64 * 1024);
        var chunkLength = Number(chunk.length);
        if (chunkLength === 0) {
            break;
        }

        totalBytes += chunkLength;
        if (totalBytes <= MAX_INPUT_BYTES) {
            collected.appendData(chunk);
        } else {
            oversized = true;
        }
    }

    if (oversized) {
        return null;
    }
    return ObjC.unwrap(
        $.NSString.alloc.initWithDataEncoding(
            collected,
            $.NSUTF8StringEncoding
        )
    );
}

function sanitizedEvent(payload, addFallbackTimestamp) {
    if (!payload || Array.isArray(payload) || typeof payload !== "object") {
        return null;
    }

    var eventName = payload.hook_event_name;
    var sessionID = payload.session_id;
    if (
        typeof eventName !== "string" ||
        SUPPORTED_EVENTS.indexOf(eventName) === -1 ||
        !isSafeIdentifier(sessionID)
    ) {
        return null;
    }

    var event = {};
    ALLOWED_FIELDS.forEach(function (field) {
        var value = payload[field];
        if (field === "session_id" || field === "turn_id") {
            if (isSafeIdentifier(value)) {
                event[field] = value;
            }
            return;
        }
        if (
            typeof value === "string" &&
            value.length <= MAX_FIELD_CHARACTERS
        ) {
            event[field] = value;
        }
    });

    if (
        typeof event.timestamp !== "string" ||
        isNaN(Date.parse(event.timestamp))
    ) {
        if (!addFallbackTimestamp) {
            return null;
        }
        event.timestamp = new Date().toISOString();
    }
    return event;
}

function compactJournal(text) {
    var bySession = Object.create(null);
    text.split(/\r?\n/).forEach(function (line) {
        if (!line) {
            return;
        }

        var event;
        try {
            event = sanitizedEvent(JSON.parse(line), false);
        } catch (error) {
            return;
        }
        if (!event) {
            return;
        }

        var timestamp = Date.parse(event.timestamp);
        var session = bySession[event.session_id] || {};
        if (event.hook_event_name === "UserPromptSubmit") {
            if (!session.start || timestamp >= session.start.timestamp) {
                session.start = { event: event, timestamp: timestamp };
            }
        } else if (
            event.hook_event_name === "PermissionRequest" ||
            event.hook_event_name === "PostToolUse" ||
            event.hook_event_name === "Stop"
        ) {
            if (!session.state || timestamp >= session.state.timestamp) {
                session.state = { event: event, timestamp: timestamp };
            }
        }
        bySession[event.session_id] = session;
    });

    var retained = [];
    Object.keys(bySession).forEach(function (sessionID) {
        var session = bySession[sessionID];
        if (session.start) {
            retained.push(session.start);
        }
        if (
            session.state &&
            (!session.start || session.state.timestamp >= session.start.timestamp)
        ) {
            retained.push(session.state);
        }
    });
    retained.sort(function (left, right) {
        return left.timestamp - right.timestamp;
    });
    return retained.map(function (entry) {
        return JSON.stringify(entry.event);
    }).join("\n");
}

function run(arguments) {
    try {
        var input = readBoundedStandardInput();
        if (input === null) {
            return "";
        }
        if (arguments.length > 0 && arguments[0] === "--compact") {
            return compactJournal(input);
        }
        var event = sanitizedEvent(JSON.parse(input), true);
        return event ? JSON.stringify(event) : "";
    } catch (error) {
        return "";
    }
}
