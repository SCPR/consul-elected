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

class ConsulElected
    constructor: (@server,@key,@command) ->
        @base_url = "http://#{@server}/v1"

        @session        = null
        @is_leader      = false

        @process        = null

        @_lastIndex     = null
        @_monitoring    = false
        @_terminating   = false

        # Set a slightly more readable title
        @_updateTitle()

        if args.watch
            debug "Setting a watch on #{ args.watch } before starting up."
            new Watch args.watch, (err) =>
                throw err if err

                if args.restart
                    # now set a normal watch on the now-existant path, so that we
                    # can restart if it changes
                    @_w = fs.watch args.watch, (evt,file) =>
                        debug "Watch fired for #{file} (#{evt})"

                # path now exists...
                @_startUp()

        else
            @_startUp()

    #----------

    _updateTitle: ->
        process.title = "consul-elected (#{ if @process then "Running" else "Waiting" })(#{@command})"

    #----------

    _startUp: ->
        @_createSession (err,id) =>
            if err
                console.error "Failed to create session: #{err}"
                process.exit(1)

            @session = id

            debug "Session ID is #{@session}"

            return false if @_terminating

            @_monitorKey()

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
                cb?()

            else
                # We did not get the lock
                @is_leader = false
                debug "Did not get leader lock."
                @_stopCommand()
                cb?()

    #----------

    _monitorKey: ->
        if @_monitoring
            return false

        debug "Starting key monitor request."
        @_monitoring = true

        # on our first lookup, we won't yet have @_lastIndex and we'll just
        # want an answer back right away to see if there is an existing leader

        opts =
            if @_lastIndex
                wait:   '10m'
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

            @_lastIndex = resp.headers['x-consul-index']
            debug "Last index is now #{ @_lastIndex }"

            @_monitoring = false

            if body && body[0]?.Session
                # there is a leader... poll again
                debug "Leader is #{ if body[0].Session == @session then "Me" else body[0].Session }. Polling again."
                @_monitorKey()
            else
                # no leader... jump in
                @_attemptKeyAcquire =>
                    @_monitorKey()

    #----------

    _runCommand: ->
        debug "Should start command: #{@command}"

        if @process
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

        # we want to restart when the watch triggers a change event
        @_w?.on "change", (evt,file) =>
            # send a kill, then let our normal exit code handle the restart
            debug "Triggering restart after watched file change."
            @process.p.kill()

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

process.on 'SIGINT', ->
    elected.terminate ->
        debug "Consul Elected exiting."
        process.exit()
