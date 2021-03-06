app = require('express.io')()
esprima = require 'esprima'
fs = require 'fs'
path = require 'path'
_ = require 'lodash'

confPath = path.join process.cwd(), 'lichtenberg'
config = if fs.existsSync("#{confPath}.json")
  require confPath
else
  console.error 'No lichtenberg.json found in the current directory.'
  process.exit -1

config.serveAs ?= '/'

if config.exclude?
  config.exclude = config.exclude.map (x)-> new RegExp x

unless config.serveAs.match /\//
  config.serveAs = "#{config.serveAs}/"

addLichtenberg = require './lib/modifyHTML'

app.http().io()

instrument = require './lib/instrument'

# `bergs` keeps track of instances.
bergs = {}

app.io.route 'ready', (req) ->
  id = req.data.id
  bergs[id] = {}

app.io.route 'done', (req) ->
  id = req.data.id
  totalExpected = 0
  totalTraced = 0
  _.values(bergs[id].files).forEach (file) ->
    file.totalExpected = 0
    file.totalTraced = 0
    _.values(file.lines).forEach (range) ->
      file.totalExpected++
      if range.executed
        file.totalTraced++
  req.io.emit 'results', bergs[id]

app.io.route 'expect', (req) ->
  return unless req.data?.range?
  id = req.data.id
  fnm = req.data.filename
  range = "#{req.data.range[0]}:#{req.data.range[1]}"
  unless bergs[id]?.files?
    bergs[id] = {files:{}}
  unless bergs[id].files[fnm]?
    bergs[id].files[fnm] = {lines:{}}
  unless bergs[id].files[fnm].lines[range]?
    bergs[id].files[fnm].lines[range] = req.data
  row = bergs[id].files[fnm].lines[range]
  row.type = req.data.type
  row.executed = 0

app.io.route 'trace', (req) ->
  # TODO need to test if req.data is an array!
  # if it's an array we can buffer it.
  return unless req.data?.range?
  id = req.data.id
  fnm = req.data.filename
  range = "#{req.data.range[0]}:#{req.data.range[1]}"
  unless bergs[id]?.files?
    bergs[id] = {files:[]}
  unless bergs[id].files[fnm]?
    bergs[id].files[fnm] = {lines:{}}
  unless bergs[id].files[fnm].lines[range]?
    row = bergs[id].files[fnm].lines[range] = req.data
    row.executed = 0
  row = bergs[id].files[fnm].lines[range]
  row.executed++

app.io.route 'instrument', (req) ->
  code = req.data.code
  req.io.emit 'instrument', code: instrument(code, req.data)

# If we go to the root, redirect to the test page.
app.get '/', (req, res) -> res.redirect path.join config.serveAs, config.entry

# Serve the main test page.
app.get path.join(config.serveAs,config.entry), (req, res) ->
  addLichtenberg config.entry, callback: (err, html)->
    if err then return res.status(500).send err.toString()
    res.send html

# Serve any JS files that the tests depend on, instrumenting as needed.
app.get new RegExp(path.join config.serveAs, '.*\.js$'), (req, res, next) ->
  fnm1 = req.path.replace config.serveAs, ''
  fnm = path.join process.cwd(), fnm1
  if config.exclude? and _.any(config.exclude, (x) -> fnm.match x)
    return next()
  if fs.existsSync fnm
    fs.readFile fnm, (err, code) ->
      if err then return res.status(500).send err.toString()
      res.send instrument(code, filename:fnm1)
  else
    next()

app.get new RegExp(path.join '/lichtenberg/original', '.*\.js$'), (req, res) ->
  fnm1 = req.path.replace '/lichtenberg/original', ''
  fnm = path.join process.cwd(), fnm1
  if fs.existsSync fnm
    fs.readFile fnm, (err, code) ->
      if err
        res.status(500).end err.toString()
      else
        res.send code
  else
    res.status(404).end('File not found')

# Serve the files that the tests depend on.
app.get new RegExp(path.join config.serveAs, '.*'), (req, res, next) ->
  fnm = req.path.replace config.serveAs, ''
  fnm = path.join process.cwd(), fnm
  if fs.existsSync fnm
    res.sendfile fnm
  else
    next()

# Serve static files that Lichtenberg depends on.
app.get /\/.*/, (req, res) ->
  fnm = "#{__dirname}/public#{req.path}"
  if fs.existsSync(fnm)
    res.sendfile fnm
  else
    fnm = path.join __dirname , req.path.replace /^\/lichtenberg\/vendor/, "/bower_components"
    if fs.existsSync fnm
      res.sendfile fnm
    else
      res.status(404).send "nope, no #{fnm}"

app.listen(9796)
console.log "Listening on port 9796"
