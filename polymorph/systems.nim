import macros, strutils, strformat, components, typetraits, sequtils, times, sharedtypes,
  private/utils, tables
export macros

template newEntityTemplate*: ComponentList = @[]
proc initComponents*: ComponentList = @[]

proc indexInit(sysNode: NimNode, options: ECSSysOptions): NimNode =
  case options.indexFormat
  of sifTable:
    quote do:
      `sysNode`.index = initTable[EntityId, int]() 
  of sifArray:
    newEmptyNode()
  of sifAllocatedSeq:
    # Requires + 1 for array as 0 is invalid.
    let initSize = newIntLitNode(options.maxEntities + 1)
    quote do:
      `sysNode`.index = newSeq[tuple[exists: bool, row: Natural]](`initSize`)

proc makeSystemType(options: ECSSysOptions, componentTypes: NimNode, extraFields: seq[NimNode]): NimNode =
  ## Generates the type declaration for this system.
  let
    name = options.name
    sysTypeName = systemTypeName(name)
    sysIdent = ident sysTypeName
    tupleTypeIdent = ident(tupleName(name))
  result = newStmtList()

  # TODO: Check if already imported.
  if options.indexFormat == sifTable:
    result.add(quote do:
      import tables
    )

  # Generate the tuple type we'll be using
  # Generate the type for this system
  result.add(quote do:
    type
      `sysIdent`* = object
        lastIndex: int            ## Records the last item position processed for streaming.
        streamRate*: Natural      ## Rate at which this system streams items by default, overridden if defined using `stream x:`.
        # TODO: Currently writable, use sys.name to get a generated constant by system type.
        systemName*: string       ## Name is automatically set up at code construction in defineSystem
        disabled*: bool           ## Doesn't run doProc if true, no work is done.
        paused*: bool             ## Pauses this system's entity processing, but still runs init & finish. 
        initialised*: bool        ## Automatically set to true after an `init` body is called.
  )

  var
    # Extract field list so we can edit them.
    fields = result.recList(sysTypeName)
    highIdx, count: NimNode
  doAssert fields.kind != nnkEmpty, "Internal error: Cannot retrieve fields from system type `" & name & "`"

  # Create requirements array
  let
    requirementsIdx = sysRequirements.high    # Updated by createSysTuple.
    reqCount = sysRequirements[requirementsIdx].len
  fields.add genField("requirements", false, genArray(reqCount, ident "ComponentTypeId"))

  # Append groups field to system's type, depending on options.
  case options.storageFormat
  of ssSeq:
    fields.add genField("groups", true, genSeq(tupleTypeIdent))
    highIdx = quote do:
      template high*(system: `sysIdent`): int = system.groups.high
    count = quote do:
      template count*(system: `sysIdent`): int = system.groups.len
  of ssArray:
    let maxEntities = options.maxEntities
    fields.add genField("groups", true, genArray(maxEntities, tupleTypeIdent))
    # TODO: Make nextFreeIdx private. This is exposed due to `newEntityWith` not building a proc, so needs internal access.
    fields.add genField("nextFreeIdx", true, ident "int")
    highIdx = quote do:
      template high*(system: `sysIdent`): int = system.nextFreeIdx - 1
    count = quote do:
      template count*(system: `sysIdent`): int = system.nextFreeIdx

  # Define the `index` field, used to translate from entityId to the groups row. 
  case options.indexFormat
  of sifTable:
    fields.add genField("index", true, genTable(ident "EntityId", ident "int"))
  of sifArray:
    let existsTuple = quote: tuple[exists: bool, row: Natural]
    # Requires + 1 for array as 0 is invalid.
    fields.add genField("index", true, genArray(options.maxEntities + 1, existsTuple))
  of sifAllocatedSeq:
    let existsTuple = quote: tuple[exists: bool, row: Natural]
    fields.add genField("index", true, genSeq(existsTuple))

  # Add fields to support timing the system.
  if options.timings == stProfiling:
    # Time to run one tick's worth of items based on past performance
    fields.add genField("timePerGroupRun", true, ident "float")
    # Calculate time taken to perform one row item based on past performance
    fields.add genField("timePerGroupItem", true, ident "float")
    fields.add genField("minTimePerGroupItem", true, ident "float")
    fields.add genField("maxTimePerGroupItem", true, ident "float")
    fields.add genField("minTimePerGroupRun", true, ident "float")
    fields.add genField("maxTimePerGroupRun", true, ident "float")
  if options.timings in [strunEvery, stProfiling]:
    # Keeps track of the last time a tick was issued
    fields.add genField("lastTick", true, ident "float")
    # In theory, inputting a negative curTime() + x in runEvery would allow no trigger until x
    # had passed, then act as if runEvery is zero (ie; always run)
    ## If runEvery is non-zero, this system's do proc will only trigger after this delay
    fields.add genField("runEvery", true, ident "float")
    fields.add genField("lastRun", true, ident "float")

  # Finally, add extra fields (provided by the user) to the type.
  if extraFields.len > 0:
    fields.add(extraFields)

  result.add(quote do:
    `highIdx`
    `count`
  )

proc instantiateSystem(options: ECSSysOptions, sysName: string, fieldSetup: seq[tuple[fieldName, value: NimNode]]): NimNode =
  ## Generates an init proc that instantiates the system and initialises variables and instantiates the system variable.
  let
    requirementsIdx = sysRequirements.high    # Updated by createSysTuple.
    reqs = sysRequirements[requirementsIdx]
    typeName = ($sysName).capitalizeAscii
    sysType = ident systemTypeName(typeName)
    initParam = ident "value"
    initIdent = ident systemInitName(sysName)
    initIndex = initParam.indexInit(options)
    sysTypeName = systemTypeName(sysName)
    sysIdent = ident sysTypeName

  result = newStmtList()
  var fieldInits = newStmtList()
  # Prepend the system variable to each field's initialisation.
  for setupState in fieldSetup:
    # `value.myVar = myValue`.
    fieldInits.add newAssignment(newDotExpr(initParam, setupState.fieldName), setupState.value)

  # Build this system's requirements array for assignment in init.
  var reqsConst = nnkBracket.newTree()
  for i, req in reqs:
    reqsConst.add newDotExpr(newLit req.int, ident "ComponentTypeId")

  # Create variable for this system.
  let
    sysVar = ident systemVarName(typeName)
    typeIdent = ident tupleName(typeName)
    systemVarDecl =
      if options.useThreadVar:
        quote:
          var `sysVar`* {.global, threadVar.}: `sysIdent`
      else:
        quote:
          var `sysVar`* {.global.}: `sysIdent`

  result.add(quote do:
    `systemVarDecl`
    ## This template returns the tuple type for this System.
    template tupleType*(system: `sysType`): untyped = `typeIdent`
  )

  # Add utility operations for this system.
  let timingsProcs =
    if options.timings == stProfiling:
      quote do:
        proc timePerItem*(sys: `sysIdent`): float {.inline.} = sys.timePerGroupItem
        proc minTimePerItem*(sys: `sysIdent`): float {.inline.} = sys.minTimePerGroupItem
        proc maxTimePerItem*(sys: `sysIdent`): float {.inline.} = sys.maxTimePerGroupItem
        proc minTimePerRun*(sys: `sysIdent`): float {.inline.} = sys.minTimePerGroupRun
        proc maxTimePerRun*(sys: `sysIdent`): float {.inline.} = sys.maxTimePerGroupRun
        proc resetMinMax*(sys: var `sysIdent`) {.inline.} =
          sys.minTimePerGroupItem = 0.0
          sys.maxTimePerGroupItem = 0.0
          sys.minTimePerGroupRun = 0.0
          sys.maxTimePerGroupRun = 0.0
        proc timePerRun*(sys: `sysIdent`): float {.inline.} = sys.timePerGroupRun
    else: newEmptyNode()

  result.add(quote do:
    proc `initIdent`*(`initParam`: var `sysIdent`) =
      ## Initialise the system.

      ## The sys template represents the system variable being passed.
      template sys: untyped {.used.} = `initParam`
      ## The self template represents the system variable being passed.
      template self: untyped {.used.} = `initParam`

      `initIndex`
      `initParam`.streamRate = 10 # Default items to process per frame when using `stream:`.
      `initParam`.requirements = `reqsConst`
      `initParam`.systemName = `sysName`
      `fieldInits`

    `timingsProcs`

    proc name*(sys: `sysIdent`): string = `sysName`
    
    # Call init proc to set up the system's variable.
    `sysVar`.`initIdent`()
  )

proc processPragma(identNode, valueType: NimNode): tuple[ident: NimNode, def: NimNode] =
  # Process and remove `public` pragma if present.
  identNode[1].expectKind nnkPragma
  for pIdx in countDown(identNode[1].len - 1, 0):
    if identNode[1][pIdx].kind == nnkIdent:
      let pragmaStr = identNode[1][pIdx].strVal

      if pragmaStr == "public" or pragmaStr == "pub":
        identNode[1].del(pIdx)
        # Mark as exported.
        identNode[0] = postFix(identNode[0], "*")
        break

  var a, b: NimNode

  if identNode[0].len > 1:
    a = identNode[0][1]
  else:
    a = identNode[0]

  if identNode[1].len == 0:
    # Public was the only pragma so remove the pragma tree entirely.
    b = newIdentDefs(identNode[0], valueType)
  else:
    b = newIdentDefs(identNode, valueType)
  (a, b)

proc parsePublicPragma(identNode, valueType: NimNode): (NimNode, NimNode) =
  ## Parse the ident node for an ident def and if it finds a {.public.}
  ## annotation, postfix the ident with `*` so the field is exported.
  ## This is necessary because `ident*` invalid syntax in an
  ## untyped block.
  case identNode.kind
  of nnkPragmaExpr:
    # Strip out public pragma (but keep others).
    identNode.processPragma(valueType)
  of nnkInfix:
    if identNode.len >= 1:
      if identNode[1].kind == nnkPragmaExpr:
        identNode[1].processPragma(valueType)
      else:
        (identNode[1], newIdentDefs(identNode[1], valueType))
    else:
      (identNode, newIdentDefs(identNode, valueType))
  else:
    (identNode, newIdentDefs(identNode, valueType))

proc matchesTypeProvided(node: NimNode): bool =
  ## Tests to see if we're doing `field -> type`.
  node.kind == nnkInfix and node[0].kind == nnkIdent and node[0].strVal == "->"

proc createSysTuple(sysName: string, componentTypes: NimNode, extraFields: NimNode, sysOptions: ECSSysOptions): NimNode =
  ## Create a tuple to hold the required combination of types for this system.
  doAssert sysName notin systemNames, "System \"" & sysName & "\" has already been defined"
  doAssert componentTypes.len > 0, "Systems require at least one type to operate on but none have been provided (missing a defineSystem?)"
  if sysOptions.indexFormat in [sifArray, sifAllocatedSeq] and sysOptions.maxEntities == 0:
    error "System \"" & sysName & "\", system options: maxEntities cannot be zero when using a fixed size type"

  # Update system names compile-time list
  systemNames.add(sysName)

  var opts = sysOptions
  # Update read-only name to ensure it's is in sync with sysName.
  opts.setName sysName
  ecsSysOptions.add(opts)
  when defined debugSystemOptions:
    echo "=== System generation options for " & sysName & " ===\n", opts.repr
  let sysIndex = ecsSysOptions.high

  # Update compile-time record of requirements by system.
  sysRequirements.add(@[])
  let requirementsIdx = sysRequirements.high

  # Add sysVar to compile-time node for later processing.
  let typeName = ($sysName).capitalizeAscii
  allSystemsNode.add ident(systemVarName(typeName))

  var elements = nnkTupleTy.newTree()
  # Add entity field.
  elements.add(nnkIdentDefs.newTree(ident("entity"), ident("EntityRef"), newEmptyNode()))
  # Add rest of fields.
  var typeIdents: seq[NimNode]
  for item in componentTypes:
    elements.add(nnkIdentDefs.newTree(
      ident(($item).toLowerAscii), ident(($item).instanceTypeName()), newEmptyNode())
    )
    let id = typeStringToId($item)
    sysRequirements[requirementsIdx].add(id)
    typeIdents.add item
  sysTypes.add typeIdents
  
  # Build system tuple type and access variable.
  let typeIdent = ident(tupleName(typeName))

  result = newStmtList()

  # Add type that will define the `groups` field.
  result.add(quote do:
    type `typeIdent`* = `elements`)

  # Add user defined fields to this System's type
  # These can be defined as `Field: Value`, `Field = Value`, or `Field -> Type = Value`.
  var
    fieldSetup: seq[tuple[fieldName, value: NimNode]]
    extraFieldDefs: seq[NimNode]

  if extraFields.kind != nnkEmpty:
    for tyDef in extraFields:
      case tyDef.kind
      of nnkCall:
        # Already in the right format.
        tyDef[1].expectKind nnkStmtList
        tyDef[1].expectMinLen 1
        let
          valueType = tyDef[1][0]
          #identDef = newIdentDefs(tyDef[0], valueType)
          (_, identDef) = parsePublicPragma(tyDef[0], valueType)

        extraFieldDefs.add(identDef)
      of nnkAsgn:
        # Because it's invalid syntax to use `field: type = statement`
        # you can manually set the type using `field -> type = statement`
        # Otherwise, use `field: type` and set it up with `init:` in the system.
        var valueType: NimNode
        let value = tyDef[1]
        if tyDef[0].matchesTypeProvided:
          # Pull out user's type request.
          valueType = tyDef[0][2]
        else:
          # Try and work out what type we have.
          valueType = value.assignmentType
        let (ident, identDef) = parsePublicPragma(tyDef[0], valueType)

        # Add assignment to the init procedure.
        fieldSetup.add (ident, value)
        # Record the field def too.
        extraFieldDefs.add(identDef)
      else: error "Unhandled kind for extra field in system \"" & sysName & "\", expected `field: type` or `field = value`, got:\n" & tyDef.treeRepr
  # Generate the system type according to provided options.
  result.add makeSystemType(opts, componentTypes, extraFieldDefs)
  result.add instantiateSystem(opts, sysName, fieldSetup)

  ecsSystemsToBeSealed.add SystemIndex(sysIndex)
  ecsSysDefined.add(SystemIndex(sysIndex), true)

  genLog "# SysTuple: ", result.repr

macro defineSystem*(name: static[string], componentTypes: openarray[typedesc], options: static[ECSSysOptions], extraFields: untyped): untyped =
  ## Forward-define a system and it's types, providing extra fields to incorporate into the resultant system instance.
  result = createSysTuple(name, componentTypes, extraFields, options)

template defineSystem*(name: static[string], componentTypes: openarray[typedesc], options: static[ECSSysOptions]): untyped =
  ## Forward-define a system and it's types using options.
  defineSystem(name, componentTypes, options, nil)

template defineSystem*(name: static[string], componentTypes: openarray[typedesc]): untyped =
  ## Forward-define a system and it's types using the default system options.
  defineSystem(name, componentTypes, defaultSystemOptions, nil)

template updateTimings*(sys: untyped): untyped =
  # per item
  # max
  if sys.timePerGroupItem > sys.maxTimePerGroupItem:
    sys.maxTimePerGroupItem = sys.timePerGroupItem
  # min
  if sys.minTimePerGroupItem <= 0.0: 
    sys.minTimePerGroupItem = sys.timePerGroupItem
  else:
    if sys.timePerGroupItem < sys.minTimePerGroupItem:
      sys.minTimePerGroupItem = sys.timePerGroupItem
  # per run
  # max
  if sys.timePerGroupRun > sys.maxTimePerGroupRun:
    sys.maxTimePerGroupRun = sys.timePerGroupRun
  # min
  if sys.minTimePerGroupRun <= 0.0: 
    sys.minTimePerGroupRun = sys.timePerGroupRun
  else:
    if sys.timePerGroupRun < sys.minTimePerGroupRun:
      sys.minTimePerGroupRun = sys.timePerGroupRun

proc generateSystem(name: string, componentTypes: NimNode, options: ECSSysOptions, extraFields: NimNode, systemBody: NimNode): NimNode =
  ## Create the processing loop to 'tick' the system.

  let
    typeName = name.capitalizeAscii
    typeIdent = ident(tupleName(typeName))
    sysId = ident(systemVarName(name))
    sys = ident "sys"

  var sysIdxSearch = name.findSystemIndex

  result = newStmtList()

  if sysIdxSearch[0]:
    # This system has already been defined.
    let
      existingSysIdx = sysIdxSearch[1]
      types = sysTypes[existingSysIdx]
    if componentTypes.len > 0 and types.len > 0 and types.repr != componentTypes.repr:
      error "Component types passed to makeSystem " & componentTypes.repr & " for system \"" & name & "\" in conflict with previous definition in defineSystem: " & types.repr

    if ecsSysBodiesAdded.hasKey(sysIdxSearch[1].SystemIndex):
      error "System \"" & name & "\" already has a body defined"

    echo "Adding body to pre-defined system ", name, " with types ", types.repr
  else:
    # This is an inline makeSystem.
    echo "Defining system and body ", name, " with types ", componentTypes.repr
    result.add createSysTuple(name, componentTypes, extraFields, options)
    sysIdxSearch = name.findSystemIndex

  var
    initBody = newStmtList()
    startBody = newStmtList()
    finishBody = newStmtList()
    allBody = newStmtList()
    allWrapper = newStmtList()
    streamBody = newStmtList()
    streamWrapper = newStmtList()
  assert sysIdxSearch[0], "Cannot find system options for \"" & name & "\""
  let sysIndex = sysIdxSearch[1]
  let options = ecsSysOptions[sysIndex]

  if systemBody == nil:
    error "makeSystem needs a `body`"

  systemBody.expectKind nnkStmtList

  var
    streamAmount = newEmptyNode()
    multipass: bool
  const
    initStr = "init"
    startStr = "start"
    allStr = "all"
    finishStr = "finish"
    streamStr = "stream"
    # commands
    multipassStr = "multipass"
    verbChoices = initStr & "," & startStr & "," & allStr & "," & streamStr & ", or " & finishStr

  for item in systemBody:
    # Here we expect `body: <statements>`
    if item.kind notin [nnkCall, nnkCommand]: continue

    doAssert item[0].kind in [nnkIdent, nnkSym],
      "In system \"" & name & "\" expected command: " & verbChoices & " but got " & item[0].repr
    let
      verb = $item[0]
      code = item[1]

    case verb.toLowerAscii
    of initStr:
      item[1].expectKind nnkStmtList
      initBody.add(quote do: `code`)
    of startStr:
      item[1].expectKind nnkStmtList
      startBody.add(quote do: `code`)
    of allStr:
      item[1].expectKind nnkStmtList
      allBody = code
    of finishStr:
      item[1].expectKind nnkStmtList
      finishBody.add(quote do: `code`)
    of streamStr:
      case code.kind
      of nnkIntLit:
        # Provided a stream amount `stream 10:` or `stream expression:`.
        item.expectLen 3

        item[2].expectKind nnkStmtList
        streamBody = item[2]

      of nnkCommand:
        # Extra command/parameter eg `stream multipass variable:`.
        # Currently only one command that accepts a parameter for stream.
        item[1].expectLen 2
        item[1][0].expectKind nnkIdent

        assert item[1][0].strVal.toLowerAscii == multipassStr, "Only multipass can take an extra parameter"
        multipass = true

        streamAmount = item[1][1]

        item[2].expectKind nnkStmtList
        streamBody = item[2]
      of nnkIdent:
        if item[1].strVal.toLowerAscii == multipassStr:
          # Trap `stream multipass:`.
          # Since we're not providing a value or other ident, the system.streamRate will be used.
          multipass = true
        else:
          # Allow `stream myVar:`
          streamAmount = item[1]
        item[2].expectKind nnkStmtList
        streamBody = item[2]
      else:
        # No stream parameters
        code.expectKind nnkStmtList
        streamBody = code
    else: error(&"makeSystem: Unknown verb \"{verb}\", expected {verbChoices}")

  if initBody.len == 0 and startBody.len == 0 and allBody.len == 0 and streamBody.len == 0 and finishBody.len == 0: error("Systems must do something within " & verbChoices)

  proc timeWrapper(core: NimNode): NimNode =
    ## Wraps `core` with timing code if `timings` is true, otherwise passes through `core` unchanged.
    case options.timings
    of stNone:
      `core`
    of stRunEvery:
      quote do:
        let startTime = cpuTime()
        `core`
        # record last tick time
        `sys`.lastTick = startTime
    of stProfiling:
      quote do:
        let startTime = cpuTime()
        `core`
        let endTime = cpuTime()
        `sys`.timePerGroupRun = endTime - startTime
        `sys`.timePerGroupItem = `sys`.timePerGroupRun / `sys`.count.float
        # Note that the min/max timers are user handled with `system.resetMinMax`.
        `sys`.updateTimings()
        # record last tick time
        `sys`.lastTick = startTime

  ##
  ## All body
  ##

  let
    # All-items body.
    idx = genSym(nskVar, "i")
    sysLen = ident "sysLen"
    gi = ident "gi"
    # if `entity` != `item.entity` then this row has been removed.
    rowEnt = ident "entity"
    allCore = quote do:

      static:
        inSystem = true
        inSystemStream = false
        inSystemAll = true
        inSystemIndex = `sysIndex`.SystemIndex
        sysRemoveAffectedThisSystem = false
        systemCalledDelete = false
        systemCalledDeleteEntity = false

      var `sysLen` = `sys`.count()
      if `sysLen` > 0:
        var `idx`: int
        while `idx` < `sysLen`:
          ## The entity this row started execution with.
          let `rowEnt` {.used.} = `sys`.groups[`idx`].entity
          ## Read only index into `groups`.
          template groupIndex: auto {.used.} =
            let `gi` = `idx`
            `gi`
          ## Current system item being processed.
          template item: `typeIdent` {.used.} = `sys`.groups[`idx`]
          template deleteEntity: untyped {.used.} =
            ## Convenience shortcut for deleting just this row's entity.
            # Although we know this delete only affects this row, we don't
            # know that it definitely will (for example if the deleteEntity depends on a 
            # condition). As such we still need to check the length each iteration.
            static:
              inSystemDeleteRow = true
              systemCalledDeleteEntity = true
            `rowEnt`.delete
            static: inSystemDeleteRow = false
          # Inject the statements from `all:`
          `allBody`
          when systemCalledDeleteEntity or systemCalledDelete or sysRemoveAffectedThisSystem:
            `sysLen` = `sys`.count()
            if `sysLen` > 0 and (`idx` < `sysLen` and `sys`.groups[`idx`].entity == `rowEnt`):
              # This row wasn't deleted so move forward.
              `idx` = `idx` + 1
          else:
            `idx` = `idx` + 1
      static:
        if defined(debugSystemPerformance):
          if systemCalledDelete:
            echo "Info: System " & `name` & " uses an arbitrary delete, length must be checked each iteration"
          elif sysRemoveAffectedThisSystem:
            echo "Info: System " & `name` & " calls a remove that affects this system, length must be checked each iteration"
          elif systemCalledDeleteEntity:
            echo "Info: System " & `name` & " calls deleteEntity, length must be checked each iteration"
        inSystem = false
        inSystemAll = false
        sysRemoveAffectedThisSystem = false
        systemCalledDelete = false
        systemCalledDeleteEntity = false
  sysCheckLengthPerIter = false

  # Build the all items node.
  let timeWrapperAll = timeWrapper(allCore)
  if allBody.len > 0:
    allWrapper.add(quote do:
      `timeWrapperAll`
    )

  ##
  ## Streaming body
  ##

  # Use default stream rate if not provided.
  if streamAmount.kind == nnkEmpty: streamAmount = quote do: `sys`.streamRate
  let
    firstItem = ident "firstItem"
    # Multi-pass forces `streamAmount` process events even if it means repeating items.
    passProcess = 
      if multipass:
        newEmptyNode()
      else:
        quote do:
          if `sys`.lastIndex == `firstItem`: break

  let
    # Streaming body.

    streamCore = quote do:
      # loop per entity in system

      # Note that streaming bodies always check the length each iteration so
      # there's no need to modify generation when a delete is called.
      static:
        inSystem = true
        inSystemStream = true
        inSystemAll = false
        inSystemIndex = `sysIndex`.SystemIndex
        sysRemoveAffectedThisSystem = false

      var sysLen = `sys`.count()
      if sysLen > 0:
        let `firstItem` = `sys`.lastIndex
        var processed: int
        while processed < `streamAmount`:
          ## The entity this row started execution with.
          let `rowEnt` {.used.} = `sys`.groups[`idx`].entity
          ## Read only index into `groups`.
          template groupIndex: auto {.used.} =
            let r = `sys`.lastIndex
            r
          ## Current system item being processed.
          template item: `typeIdent` = `sys`.groups[`sys`.lastIndex]
          ## Use `reprocessRow` when manually deleting the current row's entity if you want to guarantee no skipped items.
          template reprocessRow: untyped {.used.} =
            `sys`.lastIndex = max(0, `sys`.lastIndex - 1)
          template deleteEntity: untyped {.used.} =
            ## Convenience shortcut for deleting just this row's entity.
            `rowEnt`.delete
          
          # Inject stream statements.
          `streamBody`
          
          processed = processed + 1
          `sys`.lastIndex = `sys`.lastIndex + 1
          sysLen = `sys`.count()
          # Wrap
          if `sys`.lastIndex >= sysLen: `sys`.lastIndex = 0
          # Limit processing to one pass if not multipassing.
          `passProcess`
      
      static:
        inSystem = true
        inSystemStream = false

  let timeWrapperStream = timeWrapper(streamCore)
  if streamBody.len > 0:
    streamWrapper = quote do:
      `timeWrapperStream`

  inSystemStream = false
  
  # Generate list of types for system comment.
  var sysTypeNames: string
  for typeName in systemTypesStr(sysIndex.SystemIndex):
    if sysTypeNames != "": sysTypeNames &= ", "
    sysTypeNames &= typeName

  let
    doSystem = ident(doProcName(name))
    systemComment = newCommentStmtNode("System " & name & ", using components " & sysTypeNames)
    sysType = ident systemTypeName(name)
    runCheck =
      case options.timings
      of stNone:
        quote do: not `sys`.disabled
      of stRunEvery, stProfiling:
        quote do: (not `sys`.disabled) and ((`sys`.runEvery == 0.0) or (cpuTime() - `sys`.lastTick >= `sys`.runEvery))
    initWrapper =
      if initBody.len > 0:
        quote do:
          if unlikely(not `sys`.initialised):
            `initBody`
            `sys`.initialised = true
      else:
        initBody

  var  echoRun, echoInit, echoAll, echoFinish, echoCompleted = newEmptyNode()
  if options.echoRunning:
    echoRun = quote do:
      echo `name` & " running..."
    echoInit = quote do:
      echo `name` & " initialising"
    echoAll = quote do:
      echo `name` & " run all"
    echoFinish = quote do:
      echo `name` & " run finish"
    echoCompleted = quote do:
      echo `name` & " completed"

  let
    # Assemble the final proc.
    systemProc = quote do:
      proc `doSystem`*(`sys`: var `sysType`) =
        `systemComment`
        `echoRun`
        if `runCheck`:
          `echoInit`
          `initWrapper`
          `startBody`
          if not `sys`.paused:
            `echoAll`
            `allWrapper`
            `streamWrapper`
          `echoFinish`
          `finishBody`
        `echoCompleted`
      template `doSystem`*: untyped =
        `doSystem`(`sysId`)

  inSystem = false

  # Store a call to the do proc. Not linked to system number.
  runAllDoProcsNode.add(quote do: `doSystem`())

  # Store the body of the do proc.
  # The procs themselves are only accessible after commitSystem is called.
  systemProcs.add systemProc
  ecsSysBodiesAdded[sysIndex.SystemIndex] = true

  genLog "# Make system " & name & ": \n", systemProc.repr

## Options specified

macro makeSystemOptFields*(name: static[string], componentTypes: openarray[untyped], options: static[ECSSysOptions], extraFields, systemBody: untyped): untyped =
  ## Make a system, defining types, options and adding extra fields to the generated system type.
  generateSystem(name, componentTypes, options, extraFields, systemBody)

macro makeSystemOpts*(name: static[string], componentTypes: openarray[untyped], options: static[ECSSysOptions], systemBody: untyped): untyped =
  ## Make a system.
  generateSystem(name, componentTypes, options, newEmptyNode(), systemBody)

## No options specified

macro makeSystem*(name: static[string], componentTypes: openarray[untyped], systemBody: untyped): untyped =
  ## Make and define a system using `defaultSystemOptions`.
  generateSystem(name, componentTypes, defaultSystemOptions, newEmptyNode(), systemBody)

macro makeSystemBody*(name: static[string], systemBody: untyped): untyped =
  ## Make a system based on types previously defined with `defineSystem`.
  ## Used to build the body for a forward declared system.
  var found: bool
  for sysName in systemNames:
    if sysName.toLowerAscii == name.toLowerAscii:
      found = true
      break
  if not found: error "`makeSystemBody` requires a `defineSystem` for \"" & name & "\""
  generateSystem(name, newEmptyNode(), defaultSystemOptions, newEmptyNode(), systemBody)

proc matchSystemInner(ids: openArray[ComponentTypeId], actions: NimNode): NimNode =
  ## Perform some actions for all systems that have *at least* the supplied ids.
  ## This is a static operation, there's no look up at runtime.
  # TODO: Use elsewhere such as add/remove?
  var res = newStmtList()
  for sysIdx in ecsSystemsToBeSealed:
    let
      curSysIdx = sysIdx.int
      curSys = allSystemsNode[curSysIdx]
    var found = true

    for paramType in ids:
      if paramType notin sysRequirements[curSysIdx]:
        found = false
        break

    if found:
      # Equivalent to: template sys: untyped = `curSys`
      let n = nnkStmtList.newTree(
        nnkTemplateDef.newTree(
          ident "sys", newEmptyNode(), newEmptyNode(), nnkFormalParams.newTree(ident "untyped"), newEmptyNode(), newEmptyNode(), curSys
        ))
      res.add n
      res.add(actions)
  res

macro forSystemsUsing*(typeIds: openarray[static[ComponentTypeId]], actions: untyped): untyped =
  ## Statically perform `actions` only for systems defined for these types.
  ## Systems may have other types defined but must include all of `types`.
  ## Note that typeIds must be known at compile time.
  var tIds = newSeq[ComponentTypeId](typeIds.len)
  for item in typeIds:
    tIds.add item.intVal.ComponentTypeId
  result = matchSystemInner(tIds, actions)
  genLog "# forSystemsUsing:\n", result.repr

macro forSystemsUsing*(types: openarray[typedesc], actions: untyped): untyped =
  ## Statically perform `actions` only for systems defined for these types.
  ## Systems may have other types defined but must include all of `types`.
  ## Note that types must be known at compile time.
  var typeIds = newSeq[ComponentTypeId]()
  for paramType in types:
    let paramTypeId = ($paramType).typeStringToId
    typeIds.add paramTypeId
  #
  result = matchSystemInner(typeIds, actions)
