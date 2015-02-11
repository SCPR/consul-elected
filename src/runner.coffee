debug = require("debug")("consul-elected")

Watch = require "watch-for-path"

fs      = require "fs"
os      = require "os"
cp      = require "child_process"
request = require "request"

args = require("yargs")
    .usage("Usage: $0 -s [server] -k [key] -c [command]")
    .alias
        server:     's'
        key:        'k'
        command:    'c'
    .demand(['key','command'])
    .default
        server:     "localhost:8500"
        flapping:   30
    .describe
        server:     "Consul server"
        key:        "Key for leader election"
        command:    "Command to run when elected"
        cwd:        "Working directory for command"
        watch:      "File to watch for restarts"
        restart:    "Restart command if watched path changes"
        verbose:    "Turn on debugging"
    .boolean(['restart','verbose'])
    .argv

if args.verbose
    (require "debug").enable('consul-elected')
    debug = require("debug")("consul-elected")

#----------

class ConsulElected extends require("events").EventEmitter
    constructor: (@server,@key,@command) ->
        @base_url = "http://#{@server}/v1"

        @session        = null
        @is_leader      = false

        @process        = null

        @_lastIndex     = null
        @_monitoring    = false
        @_terminating   = false

        # create a debounced function for calling restart, so that we don't
        # trigger multiple times in a row.  This would just be _.debounce,
        # but bringing underscore in for one thing seemed silly

        # Set a slightly more readable title
        @_updateTitle()

        if args.watch
            debug "Setting a watch on #{ args.watch } before starting up."
            new Watch args.watch, (err) =>
                throw err if err

                debug "Found #{ args.watch }. Starting up."

                if args.restart
                    # now set a normal watch on the now-existant path, so that we
                    # can restart if it changes
                    @_w = fs.watch args.watch, (evt,file) =>
                        debug "fs.watch fired for #{args.watch} (#{evt})"
                        @emit "_restart"

                    last_m = null
                    @_wi = setInterval =>
                        fs.stat args.watch, (err,stats) =>
                            if err
                                return false

                            if last_m
                                if Number(stats.mtime) != last_m
                                    debug "Polling found change in #{args.watch}."
                                    @emit "_restart"
                                    last_m = Number(stats.mtime)

                            else
                                last_m = Number(stats.mtime)

                    , 1000

                # path now exists...
                @_startUp()

                last_restart = null
                @on "_restart", =>
                    cur_t = Number(new Date)
                    if @process? && (!last_restart || cur_t - last_restart > 1200)
                        last_restart = cur_t
                        # send a kill, then let our normal exit code handle the restart
                        debug "Triggering restart after watched file change."
                        @process.p.kill()

        else
            @_startUp()

    #----------

    _updateTitle: ->
        process.title = "consul-elected (#{ if @process then "Running" else "Waiting" })(#{@command})"

    #----------

    _startUp: (cb) ->
        @_createSession (err,id) =>
            if err
                console.error "Failed to create session: #{err}"
                process.exit(1)

            @session = id

            debug "Session ID is #{@session}"

            return false if @_terminating

            if cb then cb() else @_monitorKey()

    #----------

    _attemptKeyAcquire: (cb) ->
        debug "Attempting to acquire leadership"
        request.put
            url:    "#{@base_url}/kv/#{@key}"
            body:   { hostname:os.hostname(), pid:process.pid }
            json:   true
            qs:     { acquire:@session }
        , (err,resp,body) =>
            throw err if err

            return false if @_terminating

            if body == true
                # We got the lock
                @is_leader = true
                debug "I am now the leader."
                @_runCommand()
                cb()

            else
                # before deciding that we're out of the running, check and
                # make sure our session is still valid
                @_checkSession (valid) =>
                    if valid
                        # ok, so we did just lose a valid election.
                        @is_leader = false
                        debug "Did not get leader lock"
                        @_stopCommand()
                        cb?()
                    else
                        # create a new session and try again
                        @_startUp =>
                            debug "Attempting election again with new session"
                            @_attemptKeyAcquire cb

    #----------

    _monitorKey: (knownLeader=false) ->
        if @_monitoring
            return false

        debug "Starting key monitor request."
        @_monitoring = true

        # on our first lookup, we won't yet have @_lastIndex and we'll just
        # want an answer back right away to see if there is an existing leader

        opts =
            if @_lastIndex
                wait:   if knownLeader then '10m' else '30s'
                index:  @_lastIndex
            else
                null

        request.get
            url:    "#{@base_url}/kv/#{@key}"
            qs:     opts
            json:   true
        , (err,resp,body) =>
            # FIXME: What should we be doing here?
            throw err if err

            return false if @_terminating

            if resp.headers['x-consul-index']
                @_lastIndex = resp.headers['x-consul-index']
                debug "Last index is now #{ @_lastIndex }"
            else
                # if we don't get an index, there's probably something wrong
                # with our poll attempt. just retry that.
                @_monitoring = false
                @_monitorKey()
                return false

            @_monitoring = false

            if body && body[0]?.Session
                # there is a leader... poll again
                debug "Leader is #{ if body[0].Session == @session then "Me" else body[0].Session }. Polling again."
                @_monitorKey(true)

                # if we're the leader, make sure our process is still healthy
                if body[0].Session == @session
                    if !@process
                        # not sure how we would arrive here...
                        debug "I am the leader, but I have no process. How so?"
                        @_runCommand()

                    else if @process?.stopping
                        # setting this to false will cause the process to restart
                        # after it exits
                        debug "Resetting process.stopping state since poll says I am the leader."
                        @process.stopping = false

            else
                # no leader... jump in
                @_attemptKeyAcquire =>
                    @_monitorKey()

    #----------

    _runCommand: ->
        debug "Should start command: #{@command}"

        if @process
            # FIXME: this is to remove old process information, but should we make
            # sure it's actually dead here? or put a bullet in it?

            @process.p.removeAllListeners()
            @process.p = null

            uptime = Number(new Date) - @process.start
            debug "Command uptime was #{ Math.floor(uptime / 1000) } seconds."

        opts = {}
        if args.cwd
            opts.cwd = args.cwd

        cmd = @command.split(" ")

        @process = p:null, start:Number(new Date), stopping:false
        @process.p = cp.spawn cmd[0], cmd[1..], opts

        @process.p.stderr.pipe(process.stderr)

        @_updateTitle()

        @process.p.on "error", (err) =>
            debug "Command got error: #{err}"
            @_runCommand() if !@process.stopping

        @process.p.on "exit", (code,signal) =>
            debug "Command exited: #{code} || #{signal}"
            @_runCommand() if !@process.stopping

    #----------

    _stopCommand: ->
        debug "Should stop command: #{@command}"

        if @process
            @process.stopping = true
            @process.p.once "exit", =>
                debug "Command is stopped."
                @process = null

                @_updateTitle()

            @process.p.kill()
        else
            debug "Stop called with no process running?"

    #----------

    _checkSession: (cb) ->
        debug "Checking that our session is still valid"
        request.get
            url:    "#{@base_url}/session/info/#{@session}"
            json:   true
        , (err,resp,body) =>
            # body will be null if the session is invalid, or a JSON object
            # if valid.
            debug "checkSession body is ", body
            cb if body? then true else false

    #----------

    _createSession: (cb) ->
        debug "Sending session request"
        request.put
            url:    "#{@base_url}/session/create"
            body:   { Name:"#{os.hostname()}-#{@key}" }
            json:   true
        , (err,resp,body) =>
            cb err, body?.ID

    #----------

    terminate: (cb) ->
        @_terminating = true

        @_stopCommand() if @process

        destroySession = =>
            if @session
                # terminate our session
                request.put
                    url: "#{@base_url}/session/destroy/#{@session}"
                , (err,resp,body) =>
                    debug "Session destroy gave status of #{ resp.statusCode }"
                    cb()
            else
                cb()

        # give up our lock if we have one
        if @is_leader
            request.put
                url:    "#{@base_url}/kv/#{@key}"
                qs:     { release:@session }
            , (err,resp,body) =>
                debug "Release leadership gave status of #{ resp.statusCode }"
                destroySession()
        else
            destroySession()

#----------

elected = new ConsulElected args.server, args.key, args.command

_handleExit = ->
    elected.terminate ->
        debug "Consul Elected exiting."
        process.exit()

process.on 'SIGINT', _handleExit
process.on 'SIGTERM', _handleExit

