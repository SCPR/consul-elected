(function() {
  var ConsulElected, Watch, args, cp, debug, elected, fs, os, request;

  debug = require("debug")("consul-elected");

  Watch = require("watch-for-path");

  fs = require("fs");

  os = require("os");

  cp = require("child_process");

  request = require("request");

  args = require("yargs").usage("Usage: $0 -s [server] -k [key] -c [command]").alias({
    server: 's',
    key: 'k',
    command: 'c'
  }).demand(['key', 'command'])["default"]({
    server: "localhost:8500",
    flapping: 30
  }).describe({
    server: "Consul server",
    key: "Key for leader election",
    command: "Command to run when elected",
    cwd: "Working directory for command",
    watch: "File to watch for restarts",
    restart: "Restart command if watched path changes",
    verbose: "Turn on debugging"
  }).boolean(['restart', 'verbose']).argv;

  if (args.verbose) {
    (require("debug")).enable('consul-elected');
    debug = require("debug")("consul-elected");
  }

  ConsulElected = (function() {
    function ConsulElected(server, key, command) {
      this.server = server;
      this.key = key;
      this.command = command;
      this.base_url = "http://" + this.server + "/v1";
      this.session = null;
      this.is_leader = false;
      this.process = null;
      this._lastIndex = null;
      this._monitoring = false;
      this._terminating = false;
      this._updateTitle();
      if (args.watch) {
        debug("Setting a watch on " + args.watch + " before starting up.");
        new Watch(args.watch, (function(_this) {
          return function(err) {
            if (err) {
              throw err;
            }
            if (args.restart) {
              _this._w = fs.watch(args.watch, function(evt, file) {
                return debug("Watch fired for " + file + " (" + evt + ")");
              });
            }
            return _this._startUp();
          };
        })(this));
      } else {
        this._startUp();
      }
    }

    ConsulElected.prototype._updateTitle = function() {
      return process.title = "consul-elected (" + (this.process ? "Running" : "Waiting") + ")(" + this.command + ")";
    };

    ConsulElected.prototype._startUp = function() {
      return this._createSession((function(_this) {
        return function(err, id) {
          if (err) {
            console.error("Failed to create session: " + err);
            process.exit(1);
          }
          _this.session = id;
          debug("Session ID is " + _this.session);
          if (_this._terminating) {
            return false;
          }
          return _this._monitorKey();
        };
      })(this));
    };

    ConsulElected.prototype._attemptKeyAcquire = function(cb) {
      debug("Attempting to acquire leadership");
      return request.put({
        url: "" + this.base_url + "/kv/" + this.key,
        body: {
          hostname: os.hostname(),
          pid: process.pid
        },
        json: true,
        qs: {
          acquire: this.session
        }
      }, (function(_this) {
        return function(err, resp, body) {
          if (err) {
            throw err;
          }
          if (_this._terminating) {
            return false;
          }
          if (body === true) {
            _this.is_leader = true;
            debug("I am now the leader.");
            _this._runCommand();
            return typeof cb === "function" ? cb() : void 0;
          } else {
            _this.is_leader = false;
            debug("Did not get leader lock.");
            _this._stopCommand();
            return typeof cb === "function" ? cb() : void 0;
          }
        };
      })(this));
    };

    ConsulElected.prototype._monitorKey = function() {
      var opts;
      if (this._monitoring) {
        return false;
      }
      debug("Starting key monitor request.");
      this._monitoring = true;
      opts = this._lastIndex ? {
        wait: '10m',
        index: this._lastIndex
      } : null;
      return request.get({
        url: "" + this.base_url + "/kv/" + this.key,
        qs: opts,
        json: true
      }, (function(_this) {
        return function(err, resp, body) {
          var _ref;
          if (err) {
            throw err;
          }
          if (_this._terminating) {
            return false;
          }
          _this._lastIndex = resp.headers['x-consul-index'];
          debug("Last index is now " + _this._lastIndex);
          _this._monitoring = false;
          if (body && ((_ref = body[0]) != null ? _ref.Session : void 0)) {
            debug("Leader is " + (body[0].Session === _this.session ? "Me" : body[0].Session) + ". Polling again.");
            return _this._monitorKey();
          } else {
            return _this._attemptKeyAcquire(function() {
              return _this._monitorKey();
            });
          }
        };
      })(this));
    };

    ConsulElected.prototype._runCommand = function() {
      var cmd, opts, uptime, _ref;
      debug("Should start command: " + this.command);
      if (this.process) {
        this.process.p.removeAllListeners();
        this.process.p = null;
        uptime = Number(new Date) - this.process.start;
        debug("Command uptime was " + (Math.floor(uptime / 1000)) + " seconds.");
      }
      opts = {};
      if (args.cwd) {
        opts.cwd = args.cwd;
      }
      cmd = this.command.split(" ");
      this.process = {
        p: null,
        start: Number(new Date),
        stopping: false
      };
      this.process.p = cp.spawn(cmd[0], cmd.slice(1), opts);
      this.process.p.stderr.pipe(process.stderr);
      this._updateTitle();
      if ((_ref = this._w) != null) {
        _ref.on("change", (function(_this) {
          return function(evt, file) {
            debug("Triggering restart after watched file change.");
            return _this.process.p.kill();
          };
        })(this));
      }
      this.process.p.on("error", (function(_this) {
        return function(err) {
          debug("Command got error: " + err);
          if (!_this.process.stopping) {
            return _this._runCommand();
          }
        };
      })(this));
      return this.process.p.on("exit", (function(_this) {
        return function(code, signal) {
          debug("Command exited: " + code + " || " + signal);
          if (!_this.process.stopping) {
            return _this._runCommand();
          }
        };
      })(this));
    };

    ConsulElected.prototype._stopCommand = function() {
      debug("Should stop command: " + this.command);
      if (this.process) {
        this.process.stopping = true;
        this.process.p.once("exit", (function(_this) {
          return function() {
            debug("Command is stopped.");
            _this.process = null;
            return _this._updateTitle();
          };
        })(this));
        return this.process.p.kill();
      } else {
        return debug("Stop called with no process running?");
      }
    };

    ConsulElected.prototype._createSession = function(cb) {
      debug("Sending session request");
      return request.put({
        url: "" + this.base_url + "/session/create",
        body: {
          Name: "" + (os.hostname()) + "-" + this.key
        },
        json: true
      }, (function(_this) {
        return function(err, resp, body) {
          return cb(err, body != null ? body.ID : void 0);
        };
      })(this));
    };

    ConsulElected.prototype.terminate = function(cb) {
      var destroySession;
      this._terminating = true;
      if (this.process) {
        this._stopCommand();
      }
      destroySession = (function(_this) {
        return function() {
          if (_this.session) {
            return request.put({
              url: "" + _this.base_url + "/session/destroy/" + _this.session
            }, function(err, resp, body) {
              debug("Session destroy gave status of " + resp.statusCode);
              return cb();
            });
          } else {
            return cb();
          }
        };
      })(this);
      if (this.is_leader) {
        return request.put({
          url: "" + this.base_url + "/kv/" + this.key,
          qs: {
            release: this.session
          }
        }, (function(_this) {
          return function(err, resp, body) {
            debug("Release leadership gave status of " + resp.statusCode);
            return destroySession();
          };
        })(this));
      } else {
        return destroySession();
      }
    };

    return ConsulElected;

  })();

  elected = new ConsulElected(args.server, args.key, args.command);

  process.on('SIGINT', function() {
    return elected.terminate(function() {
      debug("Consul Elected exiting.");
      return process.exit();
    });
  });

}).call(this);
