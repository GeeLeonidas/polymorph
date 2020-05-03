import macros, sharedtypes, private/utils, components, strutils, tables, typetraits

macro componentToSysRequirements*(varName: untyped): untyped =
  ## Create a static sequence that matches componentTypeId to an array of indexes into systemNodes
  ## The result is an array that returns a seq of indexes into allSystemsNode by componentTypeId
  ##   `array[ComponentTypeId, seq[SystemIndex]]`
  ## This means we can check at run time what systems are required per component.
  ## Note this must only be used after seal has been called, otherwise the compile-time lists will be
  ## incomplete.
  let res = compSystems().genStaticArray()
  result = quote do:
    const `varName` = `res`
  genLog "# componentToSysRequirements:\n", result.repr

proc findType(compNode: NimNode): string =
  ## Expects a typed node and tries to extract the type name.
  case compNode.kind
  of nnkObjConstr:
    # Defined inline
    compNode.expectMinLen 1

    if compNode[0].kind == nnkDotExpr:
      compNode[0][1].strVal
    else:
      compNode[0].strVal
  of nnkSym:
    let tyImpl = compNode.getTypeInst()
    $tyImpl
  of nnkCall:
    let caller = compNode[0].getImpl()
    caller.expectKind nnkProcDef
    let callerTypeStr = $caller[3][0]
    callerTypeStr
  else:
    $(compNode.getTypeInst())

proc componentListToSet(componentIds: seq[ComponentTypeId], setType: NimNode): NimNode =
  # Add to entity set in one go.
  result = nnkCurly.newTree()
  # Add the exists flags, cast to the components enum
  for id in componentIds:
    result.add ident "ce" & tNames[id.int]

proc addCode(list: var seq[NimNode], typeIndex: int, actions: NimNode) =
  if list.len <= typeIndex:
    list.setLen typeIndex + 1
  if list[typeIndex] == nil:
    list[typeIndex] = newStmtList()
  list[typeIndex] = newStmtList(actions)

proc addCodeBlock(list: var seq[NimNode], typeIndex: int, actions: NimNode) =
  addCode(list, typeIndex, newBlockStmt(actions))

macro onAddCallback*(typeToUse: typedesc, actions: untyped): untyped =
  let typeIndex = typeStringToId($typeToUse).int
  doAssert typeIndex != 0, "Cannot find type " & $typeToUse & " in registered components "
  let
    tyName = tNames[typeIndex]
    instTypeName = ident instanceTypeName(tyName)
    cc = ident "curComponent"
    ce = ident "curEntity"
    cbProcName = ident addCallbackName(tyName)
  addCallbackProcs.addCode(typeIndex, quote do:
      proc `cbProcName`(`ce`: EntityRef, `cc`: `instTypeName`) =
        `actions`
  )
  addForwardDecls.addCode(typeIndex, quote do:
      proc `cbProcName`(`ce`: EntityRef, `cc`: `instTypeName`)
  )
  result = newEmptyNode()

macro onRemoveCallback*(typeToUse: typedesc, actions: untyped): untyped =
  let typeIndex = typeStringToId($typeToUse).int
  doAssert typeIndex != 0, "Cannot find type " & $typeToUse & " in registered components "
  let
    tyName = tNames[typeIndex]
    instType = ident instanceTypeName(tyName)
    cc = ident "curComponent"
    ce = ident "curEntity"
    cbProcName = ident removeCallbackName(tyName)
  removeCallbackProcs.addCode(typeIndex, quote do:
      proc `cbProcName`(`ce`: EntityRef, `cc`: `instType`) =
        `actions`
  )
  removeForwardDecls.addCode(typeIndex, quote do:
      proc `cbProcName`(`ce`: EntityRef, `cc`: `instType`)
      )

  result = newEmptyNode()

# These inline hooks insert code at generation, and are therefore more limited in what they can do.

macro onInit*(typeToUse: typedesc, actions: untyped): untyped =
  ## Add some code to be executed when a new component is instantiated,
  ## but before data has been added.
  ## Each invocation will append to the code that will be inserted.
  let typeIndex = typeStringToId($typeToUse).int
  doAssert typeIndex != 0, "Cannot find type " & $typeToUse & " in registered components "
  componentInitialisationCode.addCode(typeIndex, actions)
  result = newEmptyNode()

macro onInterceptUpdate*(typeToUse: typedesc, actions: untyped): untyped =
  ## Add some code to be executed when a new component is instantiated,
  ## but before data has been added.
  ## The data being added can be accessed in `curComponent`, and is of
  ## the native type, not the instance type.
  ## Each invocation will append to the code that will be inserted.
  ## Note: When this is hooked, the user must call update if they don't
  ## want the update parameters to be ignored.
  let typeIndex = typeStringToId($typeToUse).int
  doAssert typeIndex != 0, "Cannot find type " & $typeToUse & " in registered components "
  componentInterceptValueInitCode.addCodeBlock(typeIndex, actions)
  result = newEmptyNode()

macro onDelete*(typeToUse: typedesc, actions: untyped): untyped =
  ## Add some code to be executed when a component is deleted.
  ## Each invocation will append to the code that will be inserted.
  let typeIndex = typeStringToId($typeToUse).int
  doAssert typeIndex != 0, "Cannot find type " & $typeToUse & " in registered components "
  componentFinalisationCode.addCodeBlock(typeIndex, actions)
  result = newEmptyNode()

macro onAdd*(typeToUse: typedesc, actions: untyped): untyped =
  ## Add some code to be executed when a component of this type is added to an entity.
  ## Each invocation will append to the code that will be inserted.
  let typeIndex = typeStringToId($typeToUse).int
  doAssert typeIndex != 0, "Cannot find type " & $typeToUse & " in registered components "
  componentAddCode.addCodeBlock(typeIndex, actions)
  result = newEmptyNode()

macro onRemove*(typeToUse: typedesc, actions: untyped): untyped =
  ## Add some code to be executed when a component of this type is removed from an entity.
  ## Each invocation will append to the code that will be inserted.
  let typeIndex = typeStringToId($typeToUse).int
  doAssert typeIndex != 0, "Cannot find type " & $typeToUse & " in registered components "
  componentRemoveCode.addCodeBlock(typeIndex, actions)
  result = newEmptyNode()

macro onSystemAdd*(typeToUse: typedesc, actions: untyped): untyped =
  ## Add some code to be executed when a component of this type is added to any system.
  ## The system variable is provided by the `curSystem` template.
  ## Each invocation will append to the code that will be inserted.
  let typeIndex = typeStringToId($typeToUse).int
  doAssert typeIndex != 0, "Cannot find type " & $typeToUse & " in registered components "
  systemAddCode.addCodeBlock(typeIndex, actions)
  result = newEmptyNode()

macro onSystemAddTo*(typeToUse: typedesc, systemName: static[string], actions: untyped): untyped =
  ## Add some code to be executed when a component of this type is removed from this system.
  ## The system variable is provided by the `curSystem` template.
  ## Each invocation will append to the code that will be inserted.
  let
    sysIndex = findSystemIndex(systemName)
    typeIndex = typeStringToId($typeToUse).int
  doAssert typeIndex != 0, "Cannot find type " & $typeToUse & " in registered components "
  doAssert sysIndex.found, "Cannot find system \"" & systemName & "\" in defined systems: " & $systemNames
  if systemAddToCode.len <= sysIndex.index:
    systemAddToCode.setLen sysIndex.index + 1
  systemAddToCode[sysIndex.index].add (typeIndex.ComponentTypeId, newBlockStmt(actions))
  result = newEmptyNode()

macro onSystemRemove*(typeToUse: typedesc, actions: untyped): untyped =
  ## Add some code to be executed when a component of this type is removed from any system.
  ## The system variable is provided by the `curSystem` template.
  ## Each invocation will append to the code that will be inserted.
  let typeIndex = typeStringToId($typeToUse).int
  doAssert typeIndex != 0, "Cannot find type " & $typeToUse & " in registered components "
  systemRemoveCode.addCodeBlock(typeIndex, actions)
  result = newEmptyNode()

macro onSystemRemoveFrom*(typeToUse: typedesc, systemName: static[string], actions: untyped): untyped =
  ## Add some code to be executed when a component of this type is removed from this system.
  ## The system variable is provided by the `curSystem` template.
  ## Each invocation will append to the code that will be inserted.
  let
    sysIndex = findSystemIndex(systemName)
    typeIndex = typeStringToId($typeToUse).int
  doAssert typeIndex != 0, "Cannot find type " & $typeToUse & " in registered components "
  doAssert sysIndex.found, "Cannot find system \"" & systemName & "\" in defined systems: " & $systemNames
  if systemRemoveFromCode.len <= sysIndex.index:
    systemRemoveFromCode.setLen sysIndex.index + 1
  systemRemoveFromCode[sysIndex.index].add (typeIndex.ComponentTypeId, newBlockStmt(actions))
  result = newEmptyNode()

proc addUserSysCode(currentNode: var NimNode, ent: NimNode, sys: SystemIndex, typeId: ComponentTypeId, fieldIdent: NimNode) =
  let sysNode = allSystemsNode[sys.int]
  var
    addTemplates: bool
    addedCode = newStmtList()

  if sys.int < systemAddToCode.len:
    # Check if matches a specific system and component type.
    for userData in systemAddToCode[sys.int]:
      if userData.typeId == typeId:
        let userAddToSys = userData.code

        addedCode.add(quote do:
          block:
            template curEntity: EntityRef {.used.} = `ent`
            template curComponent: untyped {.used.} = `fieldIdent`
            template curSystem: untyped {.used.} = `sysNode`
            `userAddToSys`
        )

  if typeId.int < systemAddCode.len:
    # Check for this type's initialiser.
    let
      sysAdd = systemAddCode[typeId.int]
      sysNode = allSystemsNode[sys.int]
    if sysAdd != nil:
      if currentNode.len == 0: addTemplates = true
      addedCode.add(quote do:
        block:
          template curEntity: EntityRef {.used.} = `ent`
          template curComponent: untyped {.used.} = `fieldIdent`
          ## Access to current updating system variable.
          template curSystem: untyped {.used.} = `sysNode`
          `sysAdd`
      )

  if addedCode.len > 0:
    currentNode.add addedCode

proc doNewEntityWith(entOpts: ECSEntityOptions, componentList: NimNode): NimNode {.compileTime.} =
  # Note: Currently does not generate a container and writes out the innards
  # within a block statement in the caller scope.
  # Pros: No call overhead when creating entities in a tight loop, and direct
  # mechanics manipulation.
  # Consequences: All ECS mechanics must be exposed to the user.
  #   * The user can potentially mess about with the internal entity state and corrupt the ECS.
  #   * The user can work with internal states and add features that need to process this info.
  result = newStmtList()
  let
    entity = genSym(nskVar, "entity")
    entIdNode = quote: `entity`.entityId
    systemsByCompId = compSystems()
  var
    componentDecl = nnkVarSection.newTree()
    paramUpdates = newStmtList()
    addToEntity = newStmtList()
    compIds: seq[ComponentTypeId]
    statements = newStmtList()
    userCompAddCode = newStmtList()

  for component in componentList:
    let
      # Search for the type name for this node
      tyName = component.findType
      # Convert to `ComponentTypeId`
      typeId = tyName.typeStringToId
      fieldName = tyName.toLowerAscii & instPostfix
      fieldIdent = ident fieldName
      instTypeIdent = ident instanceTypeName(tyName)
      # proc to instantiate this component type.
      newProc = ident createInstanceName(tyName)

    if typeId in compIds: error "newEntityWith has been passed more than one component of type " & tyName

    # For later use in updateSystems
    compIds.add typeId

    # Create storage for this component
    let compOwner = componentSystemOwner[typeId.int]
    if compOwner != InvalidSystemIndex:
      let sysNode = allSystemsNode[compOwner.int]
      # This should correspond to the next index for groups, which is added just below.
      componentDecl.add genFieldAssignment(fieldName, false, quote do:
        `sysNode`.count.`instTypeIdent`
      )
    else:
      componentDecl.add genFieldAssignment(fieldName, false, newCall(newProc))

      # Update storage with parameter value
      paramUpdates.add(quote do:
        `fieldIdent`.update(`component`)
      )

    let compRef = quote do: `fieldIdent`.toRef
    addToEntity.add addComponentRef(entity, compRef, entOpts)

    # Component add user code.
    if typeId.int < componentAddCode.len:
      let compAdd = componentAddCode[typeId.int]
      if compAdd != nil:
        userCompAddCode.add(quote do:
          ## Current component being added to entity. 
          template curComponent: untyped {.used.} = `fieldIdent`
          `compAdd`
        )

    # User callback.
    if typeId.int < addCallbackProcs.len:
      # Check for this type's initialiser.
      let sysAddCallback = addCallbackProcs[typeId.int]
      if sysAddCallback != nil:
        let cbProcName = ident addCallbackName(tyName)
        userCompAddCode.add(quote do:
          `cbProcName`(`entity`, `fieldIdent`)
        )

  let setOp =
    if entOpts.useSet:
      let
        setType = ident enumName()
        setVal = componentListToSet(compIds, setType)
      entSetIncl(entOpts, entIdNode, setVal)
    else:
      newEmptyNode()

  var
    processed: set[int16]
    userSysAddCode = newStmtList()

  statements.add(quote do:
    var `entity` = newEntity()
    `componentDecl`
    `setOp`
  )
  
  var missingComps, ownedComps: seq[ComponentTypeId]

  for compId in compIds:      
    # Get systems that use this component.
    let ownerSystem = componentSystemOwner[compId.int]
    var satisfied = true
    if ownerSystem != InvalidSystemIndex:
      ownedComps.add compId
      let comps = sysRequirements[ownerSystem.int]
      for comp in comps:
        if comp != compId and comp notin compIds and comp notin missingComps:
          satisfied = false
          missingComps.add comp

    if satisfied:
      let systems = systemsByCompId[compId.int]
      for sys in systems:
        if sys.int16 notin processed:
          processed.incl(sys.int16)

          # We only need to update systems that are fully qualified by componentList.
          let reqs = sysRequirements[sys.int]
          var discarded: bool
          for req in reqs:
            if req notin compIds:
              discarded = true

          if not discarded:
            # Add component to system.
            statements.add genSystemUpdate(entity, sys, compIds, componentList)
            # Add user code.
            let
              fieldName = tNames[compId.int].toLower & instPostfix
              fieldIdent = ident fieldName

            userSysAddCode.addUserSysCode(entity, sys, compId, fieldIdent)

  if missingComps.len > 0:
    error "Owned component(s) [" & ownedComps.commaSeparate &
      "] need their owner systems completed with component(s): [" & missingComps.commaSeparate & "]"

  statements.add(quote do:
    let res = `entity`
    template curEntity: EntityRef {.used.} = `entity`
    `addToEntity`
    `paramUpdates`
    `userSysAddCode`
    `userCompAddCode`
    res
  )

  result = quote do:
    block:
      `statements`

  genLog "# newEntityWith " & compIds.commaSeparate & ":\n", result.repr

proc makeNewEntityWith*(entOpts: ECSEntityOptions): NimNode =
  let
    componentList = ident "componentList"
    #newEntCode = doNewEntityWith(entOpts, componentList)
  quote do:
    macro newEntityWith*(`componentList`: varargs[typed]): untyped =
      ## Create an entity with the parameter components.
      ## This macro statically generates updates for only systems
      ## entirely contained within the parameters and ensures no
      ## run time component list iterations and associated checks.
      #`newEntCode`
      doNewEntityWith(`entOpts`, `componentList`)

type ComponentParamInfo* = object
  passed*:          seq[ComponentTypeId]
  values*:          seq[NimNode]
  ## Non-owned components belonging to owner systems that haven't been passed 
  requiredFetches*: seq[ComponentTypeId]
  lookFor*:         seq[ComponentTypeId]
  ## Index into `passed`.
  generateIdx*:     seq[int]
  owned*:           seq[tuple[id: ComponentTypeId, sys: SystemIndex, passedIdx: int]]
  ## Non-owning system that may or may not be satisfied.
  unownedSystems*:  seq[SystemIndex]
  ## Systems that own passed components and must be fully satisfied.
  ownedSystems*:    seq[SystemIndex]

proc processComponentParameters(componentList: NimNode): ComponentParamInfo =
  ## Collects information from parameters passed as part of a state change.

  # Generate a list of SystemIndexes used by each ComponentTypeId.
  let systemsByCompId = compSystems()
  
  for compNode in componentList:
    let tyName = compNode.findType
    doAssert tyName != "", "Cannot determine type name of argument:\n" & compNode.treeRepr & "\ngetType:\n" & compNode.getType.repr
    
    # Find the ComponentTypeId for this type.
    let typeId = tyName.typeStringToId
    if typeId in result.passed: error "Passed more than one component of type " & tyName

    if typeId in result.passed:
      error "Component type " & tyName & " appears more than once in parameters"
    
    result.passed.add typeId
    result.values.add compNode

  # Process requirements.
  for i, typeId in result.passed:
    let
      ownerSystem = componentSystemOwner[typeId.int]
      isOwned = ownerSystem != InvalidSystemIndex
      typeStr = tNames[typeId.int]
    
    if isOwned:
      if ownerSystem notin result.ownedSystems:
        # Owning systems must have all their components fully satisfied.
        result.owned.add (typeId, ownerSystem, i)
        result.ownedSystems.add ownerSystem

        let systemComponents = sysRequirements[ownerSystem.int]
        # Add component instances that must be valid to support the owner system for a component passed.
        for comp in systemComponents:
          if comp notin result.passed:
            if comp.isOwned: error "Cannot add " & typeStr & ", missing required owned component " & tNames[comp.int]
            elif comp notin result.requiredFetches:
              result.requiredFetches.add comp
              result.lookFor.add comp

    else:
      # Passed components that are not owned must generate ComponentRefs.
      result.generateIdx.add i

    let linkedSystems = systemsByCompId[typeId.int]
    
    # Create a list of components we're missing that would potentially
    # satisfy all systems that use our parameters.
    for sys in linkedSystems:

      let sysIsOwner = systemOwnedComponents[sys.int].len > 0
      
      if not sysIsOwner:
        # Owned systems that weren't in the parameters are ignored.

        if sys notin result.unownedSystems:
          result.unownedSystems.add sys

        for typeId in sysRequirements[sys.int]:          
          if typeId notin result.passed and typeId notin result.lookFor:
            result.lookFor.add typeId

proc genComponents*(entity: NimNode, compInfo: ComponentParamInfo): NimNode =
  ## Create storage instances for passed components.
  ## Only handles non-owned components. 
  result = newStmtList()
  var
    componentDecl = nnkVarSection.newTree()
    userEventDecls = newStmtList()
    interceptPrecursor = newStmtList()

  for idx in compInfo.generateIdx:
    let
      typeId = compInfo.passed[idx]
      typeStr = tNames[typeId.int]
      instVarStr = typeStr.toLower
      instVar = ident instVarStr
      paramVal = compInfo.values[idx]

    let
      hasUserAddCode =
        typeId.int < componentAddCode.len and componentAddCode[typeId.int] != nil
      hasUserCallback = typeId.int < addCallbackProcs.len and addCallbackProcs[typeId.int] != nil

    if hasUserAddCode:
      let userCode = componentAddCode[typeId.int]
      userEventDecls.add(quote do:
        block:
          template curComponent: untyped {.used.} = `instVar`
          template curEntity: untyped {.used.} = `entity`
          `userCode`
      )
    if hasUserCallback:
      let cbProcName = ident addCallbackName(typeStr)
      userEventDecls.add(quote do:
        `cbProcName`(`entity`, `instVar`)
      )

    componentDecl.add genFieldAssignment(instVarStr, false, quote do: newInstance(`paramVal`))
  
  if interceptPrecursor.len > 0:
    result.add interceptPrecursor
  result.add componentDecl
  result.add userEventDecls

proc buildFetch(entity: NimNode, compInfo: ComponentParamInfo, entOpts: ECSEntityOptions): NimNode =
  ## Fetch the `compInfo.lookFor` components from the entity's component list into instance variables.
  result = newStmtList()
  var
    compDecl = nnkVarSection.newTree()
    fetch = newStmtList()
    fieldCounter = ident "fieldCounter"
    targetHigh = compInfo.lookFor.len

  if targetHigh > 0:
    let multipleFetches = targetHigh > 1

    if multipleFetches:
      result.add(quote do:
        var `fieldCounter`: int
      )

    case entOpts.componentStorageFormat
    of csSeq, csArray:
      # Loop through components and extract with a case statement.
      var fetchCase = nnkCaseStmt.newTree()
      let
        fetchCompIdent = ident "curComp"
        distinguisher = quote do: `fetchCompIdent`.typeId.int
      fetchCase.add distinguisher

      for typeId in compInfo.lookFor:
        let
          typeStr = tNames[typeId.int]
          fieldName = typeStr.toLowerAscii
          fieldIdent = ident fieldName
          instTypeIdent = ident typeStr.instanceTypeName

        # Create component variable to be populated by the fetch.
        compDecl.add genField(fieldName, false, instTypeIdent)

        let
          getInstance = quote do:
            `fetchCompIdent`.index
          ofBranch = nnkOfBranch.newTree(newIntLitNode(typeId.int))
          ofStmts = 
            if not multipleFetches:
              # With only one component to fetch we don't need to track count.
              newStmtList(quote do:
                `fieldIdent` = `instTypeIdent`(`getInstance`)
                break
              )
            else:
              newStmtList(quote do:
                `fieldIdent` = `instTypeIdent`(`getInstance`)
                `fieldCounter` += 1
                if `fieldCounter` == `targetHigh`: break
              )
        ofBranch.add ofStmts
        fetchCase.add ofBranch

      fetchCase.add nnkElse.newTree(newStmtList(quote do: discard))
      fetch.add(quote do:
        for `fetchCompIdent` in entityData(`entity`.entityId).componentRefs:
          `fetchCase`
      )

    of csTable:
      ## Tables can directly fetch components.
      for comp in compInfo.lookFor:
        let
          typeStr = tNames[comp.int]
          instTypeIdent = ident(typeStr.instanceTypeName)
          fieldName = typeStr.toLowerAscii & "Inst"
          fieldIdent = ident fieldName
        fetch.add(quote do:
          let `fieldIdent` = `instTypeIdent`(entityData(`entity`.entityId).componentRefs.getOrDefault(`comp`.ComponentTypeId).index)
        )

    result.add compDecl
    result.add fetch

proc checkRequired(compInfo: ComponentParamInfo): NimNode =
  ## Check fetched components that satisfy owned component systems are valid.
  result = newStmtList()
  if compInfo.requiredFetches.len > 0:
    var checkSystem: seq[NimNode]
    for typeId in compInfo.requiredFetches:
      let
        typeStr = tNames[typeId.int]
        typeField = ident typeStr.toLower
      checkSystem.add(quote do: `typeField`.alive)
    let
      matchesSystem = genInfixes(checkSystem, "and")
      unsatisfiedErrStr =
        newLit "Cannot complete this add operation because systems that own the parameter components are not fully satisfied, missing: " & compInfo.requiredFetches.commaSeparate
    result.add(quote do:
      if not(`matchesSystem`): raise newException(ValueError, `unsatisfiedErrStr`)
    )

proc addConditionalSystems(entity: NimNode, compInfo: ComponentParamInfo): NimNode =
  ## Add components to systems that have no owned components.
  ## These systems may or may not be updated depending on fetched instances.
  result = newStmtList()
  for sys in compInfo.unownedSystems:
    let
      systemNode = allSystemsNode[sys.int]
      sysTupleStr = systemNames[sys.int].tupleName
      sysTupleType = ident sysTupleStr
      sysTupleVar = ident(sysTupleStr.toLower)
      sysOpts = ecsSysOptions[sys.int]
    
    var
      checkSystem: seq[NimNode]
      updateTupleFields = newStmtList()
      userSysAddCode = newStmtList()

    updateTupleFields.add(quote do:
      `sysTupleVar`.entity = `entity`)

    let doAddSystem = addSystemTuple(systemNode, sysTupleVar, sysOpts)
    
    # Build code to fetch components 
    for typeId in sysRequirements[sys.int]:
      let
        typeStr = tNames[typeId.int]
        typeField, instanceField = ident typeStr.toLower

      # Only include systems with owned components if we have their owned comps in parameters.
      assert componentSystemOwner[typeId.int] != sys

      if typeId in compInfo.lookFor or typeId in compInfo.passed:
        if typeId notin compInfo.passed:
          checkSystem.add(quote do: `typeField`.alive)
        
        updateTupleFields.add(quote do:
          `sysTupleVar`.`typeField` = `instanceField`
        )
      
      userSysAddCode.addUserSysCode(entity, sys, typeId, typeField)
    
    let
      row = quote do: `systemNode`.high
      entId = quote do: `entity`.entityId
      updateIndex = systemNode.indexWrite(entId, row, sysOpts)

    let addToSys = quote do:
      var `sysTupleVar`: `sysTupleType`
      `updateTupleFields`
      `doAddSystem`
      `updateIndex`
      `userSysAddCode`

    if checkSystem.len > 0:
      let matchesSystem = genInfixes(checkSystem, "and")
      result.add(quote do:
        if `matchesSystem`:
          `addToSys`
      )
    else:
      result.add(quote do:
        `addToSys`
      )

proc addOwned(entity: NimNode, compInfo: ComponentParamInfo): NimNode =
  ## Assumes we have everything we need to add to owned systems.
  ## Any systems updated here must be fully qualified with their components.
  ## Where they are not given as parameters, their presence must be enforced
  ## at run-time.
  result = newStmtList()

  for sys in compInfo.ownedSystems:
    let
      systemNode = allSystemsNode[sys.int]
      sysTupleStr = systemNames[sys.int].tupleName
      sysTupleType = ident sysTupleStr
      sysTupleVar = ident(sysTupleStr.toLower)
      tupleSetup = newStmtList()
      sysOpts = ecsSysOptions[sys.int]
    var
      updateGroup = newStmtList()
      stateUpdates = newStmtList()

    updateGroup.add addSystemTuple(systemNode, sysTupleVar, sysOpts)

    # Components are assigned to variables with the same name.
    var
      assignCompRefs = nnkLetSection.newTree()
      userSysAddCode = newStmtList()
    let
      sysHighVar = genSym(nskLet, "sysHigh")
      getSysHigh = quote do: `systemNode`.high
      
    # Retrieve the last inserted system row for the component index.
    assignCompRefs.add newIdentDefs(sysHighVar, newEmptyNode(), getSysHigh)

    for typeId in sysRequirements[sys.int]:
      # Populate system tuple.
      let
        typeStr = tNames[typeId.int]
        typeField = ident typeStr.toLower
        instType = ident typeStr.instanceTypeName
        ownedByThisSystem = componentSystemOwner[typeId.int] == sys

      if ownedByThisSystem:
        # When a component is owned, it must be given as a parameter.
        let index = compInfo.passed.find(typeId)
        doAssert index > -1,
          "Cannot find owned component \"" & typeStr &
          "\" when adding to system \"" & systemNames[sys.int] & "\""

        let
          value = compInfo.values[index]
          onAddCode =
            if typeId.int < componentAddCode.len and
            componentAddCode[typeId.int] != nil:
              let userCode = componentAddCode[typeId.int]
              quote do:
                block:
                  template curComponent: untyped = `typeField`
                  template curEntity: untyped = `entity`
                  `userCode`
            else: newEmptyNode()
          
          userInitCode =
            if typeId.int < componentInitialisationCode.len and
              componentInitialisationCode[typeId.int] != nil:
                let code = componentInitialisationCode[typeId.int]
                quote do:
                  block:
                    template curEntity: untyped = `entity`
                    template curComponent: untyped = `typeField`
                    `code`
            else:
              newEmptyNode()

          updateCode =
            if typeId.int < componentInterceptValueInitCode.len and
              componentInterceptValueInitCode[typeId.int] != nil:
                # It's now the user's responsibility to call commit.
                let code = componentInterceptValueInitCode[typeId.int]
                quote do:
                  block:
                    template curEntity: untyped {.used.} = `entity`
                    template curValue: untyped {.used.} = `value`
                    template commit(value: untyped) {.used.} =
                      `sysTupleVar`.`typeField` = value
                    `code`
            else:
              quote do:
                `sysTupleVar`.`typeField` = `value`

        # Updating state lists is usually done in the component's
        # creation procs for non-owned components.
        stateUpdates.add updateOwnedComponentState(typeId, sys)      

        tupleSetup.add `updateCode`

        stateUpdates.add(quote do:
          `userInitCode`
          `onAddCode`
        )
        
        # Owned components reference the group index of their owning system.
        # Equivalent to: typeField = InstanceType(sys.high)
        assignCompRefs.add newIdentDefs(typeField, newEmptyNode(), newDotExpr(sysHighVar, instType))

      else:
        # Assign found reference.
        let instanceField = ident typeStr.toLower
        tupleSetup.add(quote do:
          `sysTupleVar`.`typeField` = `instanceField`
        )

      userSysAddCode.addUserSysCode(entity, sys, typeId, typeField)

    let
      row = quote do: `systemNode`.high
      #entId = quote do: `entity`.entityId
      updateIndex = entity.updateIndex(sys, row, sysOpts) #systemNode.indexWrite(entId, row, sysOpts)

    result.add(quote do:
      var `sysTupleVar`: `sysTupleType`
      `sysTupleVar`.entity = `entity`
    )
    if userSysAddCode.len > 0: result.add(quote do:
      template curEntity: EntityRef = `entity`
    )
    result.add tupleSetup
    result.add updateGroup
    result.add assignCompRefs
    result.add updateIndex
    result.add stateUpdates
    result.add userSysAddCode

proc doAddComponents(entOpts: ECSEntityOptions, entity: NimNode, componentList: NimNode): NimNode =
  var inner = newStmtList()

  let componentInfo = processComponentParameters(componentList)

  for typeId in componentInfo.passed:
    let
      typeStr = tNames[typeId.int]
      typeIdent = ident typeStr
    inner.add.add(quote do:
      assert `typeIdent` notin `entity`, "Component \"" & `typeStr` & "\" already exists in entity"
    )

  inner.add genComponents(entity, componentInfo)
  inner.add buildFetch(entity, componentInfo, entOpts)
  inner.add checkRequired(componentInfo)
  inner.add addOwned(entity, componentInfo)
  inner.add addToEntityList(entity, componentInfo.passed, entOpts)
  inner.add addConditionalSystems(entity, componentInfo)
  
  # Build return tuple.
  var returnType = nnkPar.newTree()
  for typeId in componentInfo.passed:
    let
      typeStr = tNames[typeId.int]
      typeIdent = ident typeStr.toLower
    returnType.add nnkExprColonExpr.newTree(typeIdent, typeIdent)
  inner.add returnType

  result = quote do:
    block:
      `inner`

  when defined(debugSystemPerformance):
    echo "AddComponents for ", componentInfo.passed.commaSeparate,
      " complete."

  genLog "\n# macro addComponents(" & componentInfo.passed.commaSeparate & "):\n", result.repr

proc makeAddComponents*(entOpts: ECSEntityOptions): NimNode =
  let
    componentList = ident "componentList"
    entity = ident "entity"
  quote do:
    macro addComponents*(`entity`: EntityRef, `componentList`: varargs[typed]): untyped =
      ## Generates efficient system updates for a set of components.
      ## Fetches are only performed if required components are not in the parameters.
      doAddComponents(`entOpts`, `entity`, `componentList`)

proc makeAddComponentDirect*(entOpts: ECSEntityOptions): NimNode =
  ## This macro adds `addComponent(entity, type)` for every component type.
  ## Generated code updates single components with the systems we know use that type
  ## at compile time.
  ## Unlike `addComponents` and `newEntityWith`, these procs only deal with one component at a time,
  ## but return the `ComponentRef` that's been added.
  result = newStmtList()
  let systemsByCompId = compSystems()
  var systemsEncountered: bool

  assert ecsComponentsToBeSealed.len > 0, "Cannot generate addComponent when no components have been defined"

  for tId in ecsComponentsToBeSealed:
    # Each component gets a direct access addComponent
    let
      typeId = tId.int
      tyNameStr = tNames[typeId]
      tyInstanceStr = instanceTypeName(tyNameStr)
      relevantSystems = systemsByCompId[typeId]
      tyIdent = ident tyNameStr
      tyInstanceIdent = ident tyInstanceStr
      entIdent = ident "entity"
      valIdent = ident "value"
      componentSysCount = relevantSystems.len
      # For generating useful comments for addComponent.
      sysNamePrefix = 
        if componentSysCount > 1:
          " This updates systems: "
        else:
          " This updates system: "
    var sysList: string

    if componentSysCount > 0:
      systemsEncountered = true

    for relevantSysIdx, systemIndex in relevantSystems:
      # Add update elements just for systems that use this component.
      let
        sysIdx = systemIndex.int
        sysName = systemNames[sysIdx]
      if systemOwnedComponents[sysIdx.int].len == 0 or
        (systemOwnedComponents[sysIdx.int].len == 1 and componentSystemOwner[tId.int] == systemIndex):
        # Record which systems are affected to update addComponent's doc comment.
        if sysList.len == 0:
          sysList &= sysNamePrefix & sysName
        else:
          if relevantSysIdx == relevantSystems.high:
            sysList &= ", and " & sysName
          else:
            sysList &= ", " & sysName
      else:
        break

    # Add some utilities for `addComponents`.
    let
      addComment = newCommentStmtNode(" Create storage for component and update, optionally returning " & tyInstanceStr & "." & sysList & ".")
      tupleField = ident tyNameStr.toLowerAscii()
      ownerSystem = componentSystemOwner[tId.int]
      sysOwnedCompCount = if ownerSystem != InvalidSystemIndex: systemOwnedComponents[ownerSystem.int].len else: 0 
    if sysOwnedCompCount == 0:
      result.add(quote do:
        proc addComponent*(`entIdent`: EntityRef, `valIdent`: `tyIdent`): `tyInstanceIdent` {.discardable.} =
          `addComment`
          `entIdent`.addComponents(`valIdent`).`tupleField`
        
        # TODO: addOrUpdate that allows granular updating fields rather than whole component item.
        proc addOrUpdate*(`entIdent`: EntityRef, `valIdent`: `tyIdent`): `tyInstanceIdent` {.discardable.} =
          ## This procedure allows you to forget about assertion failures due to duplicate adds.
          let fetched = `entIdent`.fetchComponent `tyIdent`
          if fetched.valid:
            # Replace original. No further work is required as the types or indexes have not been updated.
            fetched.update(`valIdent`)
            fetched
          else:
            # Add as normal.
            `entIdent`.addComponent `valIdent`
        
        proc addIfMissing*(`entIdent`: EntityRef, `valIdent`: `tyIdent`) =
          ## This procedure allows you to add a component only if it isn't already present.
          ## If the component is already present, no changes are made.
          if not `entIdent`.hasComponent(`tyIdent`):
            `entIdent`.addComponent `valIdent`
        )

  if not systemsEncountered:
    echo "Warning: No systems defined"

  when defined(debugSystemPerformance):
    echo "Add components direct completed."

  genLog "# Adding with single components:\n", result.repr

proc removeComponentRef(entityId, index: NimNode, componentTypeId: int, options: ECSEntityOptions): NimNode = 
  # Removes a component from entity storage.
  # * Doesn't touch systems
  # * Doesn't update the intset for hasComponent.

  let remIdx =
    if options.componentStorageFormat == csTable:
      quote do: `componentTypeId`.ComponentTypeId
    else:
      newIntLitNode(componentTypeId)

  case options.componentStorageFormat
  of csTable:
    # No error if key doesn't exist.
    quote do:
      entityData(`entityId`).componentRefs.del(`remIdx`)
  of csArray:
    quote do:
      let curHigh = entityData(`entityId`).nextCompIdx - 1
    
      if `index` < curHigh:
        # Swap last item with this one.
        entityData(`entityId`).componentRefs[`index`] = entityData(`entityId`).componentRefs[curHigh]
      # Cull length
      entityData(`entityId`).nextCompIdx -= 1
  of csSeq:
    quote do:
      # Cull length
      entityData(`entityId`).componentRefs.del(`index`)

proc userRemoveCode(systemIndex: int, system, rowIdent, entIdIdent, entity: NimNode, sysOpts: ECSSysOptions): NimNode =
  # Add user defined system remove code.
  result = newStmtList()
  for typeId in sysRequirements[systemIndex]:
    let
      typeName = tNames[typeId.int]
      instType = ident instanceTypeName(typeName)
      fieldIdent = ident typeName.toLowerAscii()
      curCompTemplate =
        if componentSystemOwner[typeId.int].int == systemIndex:
          quote do:
            template curComponent: untyped {.used.} = `instType`(`rowIdent`)
        else:
          quote do:
            template curComponent: untyped {.used.} = `system`.groups[`rowIdent`].`fieldIdent`


    if systemIndex < systemRemoveFromCode.len:
      for userData in systemRemoveFromCode[systemIndex.int]:
        if userData.typeId == typeId:
          let sysRem = userData.code
          if sysRem != nil:
            result.add(quote do:
              block:
                ## Access to the current row's entity.
                template curEntity: untyped {.used.} = `system`.groups[`rowIdent`].entity
                ## Access to the current system's row.
                template curRow: untyped {.used.} = `system`.groups[`rowIdent`]
                ## Access to current updating system variable.
                template curSystem: untyped {.used.} = `system`
                ## Component being removed from this system.
                `curCompTemplate`
                `sysRem`
            )

    if typeId.int < systemRemoveCode.len:
      let sysRem = systemRemoveCode[typeId.int]
      if sysRem != nil:
        result.add(quote do:
          block:
            ## Access to the current row's entity.
            template curEntity: untyped {.used.} = `system`.groups[`rowIdent`].entity
            ## Access to the current system's row.
            template curRow: untyped {.used.} = `system`.groups[`rowIdent`]
            ## Access to current updating system variable.
            template curSystem: untyped {.used.} = `system`
            ## Component being removed from this system.
            `curCompTemplate`
            `sysRem`
        )

proc removeSysReference(systemIndex: int, system, sysRowExists, rowIdent, entIdIdent, entity: NimNode, sysOpts: ECSSysOptions): NimNode =
  # Remove an entity's tuple from a system.
  # * Does not update the entity's storage

  let
    topIdxIdent = ident "topIdx"
    updatedRowEntIdent = ident "updatedRowEnt"
    updatedEntId = newDotExpr(updatedRowEntIdent, ident "entityId")
    # updates index with entity id to group row.
    setIndex = system.indexWrite(updatedEntId, rowIdent, sysOpts)

  let
    trimGroup = 
      case sysOpts.storageFormat
      of ssSeq:
        quote do:
          let `topIdxIdent` = `system`.high
          if `rowIdent` < `topIdxIdent`:
            `system`.groups[`rowIdent`] = `system`.groups[`topIdxIdent`]
            # Get entity that's been moved.
            let `updatedRowEntIdent` = `system`.groups[`rowIdent`][0]
            # Update the index for the moved row
            `setIndex`

          `system`.groups.setLen(`system`.groups.len - 1)
      of ssArray:
        quote do:
          let `topIdxIdent` = `system`.high
          if `rowIdent` < `topIdxIdent`:
            `system`.groups[`rowIdent`] = `system`.groups[`topIdxIdent`]
            # Get entity that's been moved.
            let `updatedRowEntIdent` = `system`.groups[`rowIdent`][0]
            # Update the index for the moved row
            `setIndex`

          `system`.nextFreeIdx -= 1
  
  let delIndex = system.indexDel(entIdIdent, sysOpts)
  let r = quote do:
    if `sysRowExists`:
      # A system might not contain a reference to this entity -
      # for example if they don't contain other required components.
      `delIndex`
      #`updateOwnedCompRef`
      # Trim system seq/array.
      `trimGroup`
  r

proc makeRemoveComponentDirect*(entOpts: ECSEntityOptions): NimNode =
  #[
    Important note!
    If you call removeComponent whilst in a system using that component, the current `item` will change!
    In this case, item.entity.removeComponent will cause item.entity and it's components to be different.
    This happens because `entity.removeComponent` and `entity.delete` remove items from systems by swapping
    the item with the last one in the list and reducing the list length.
  ]#
  let
    index = ident "index"
    entityIdent = ident "entity"
    entityIdIdent = ident "entityId"
    # Array of all types by systems
    systemsByCompId = compSystems()
    componentLen = componentRefsLen(entityIdIdent, entOpts)
    alive = ident "alive" # Late bind for this template
    rowIdent = ident "row"

  result = newStmtList()

  for typeId in ecsComponentsToBeSealed:
    let
      typeName = tNames[typeId.int]
      typeInstanceIdent = ident instanceTypeName(typeName)
      tyDelete = ident deleteInstanceName()

      compTypedesc = nnkBracketExpr.newTree(ident "typedesc", ident typeName)
      # System indexes that use the component being removed
      relevantSystems = systemsByCompId[typeId.int]
      removeIdxIdent = ident "compIdx"
      foundComp = ident "found"

    var
      updateSystems = newStmtList()
      userUpdates = newStmtList()
      visited = newSeq[bool](sysRequirements.len)
      findSysCode = newStmtList()
      foundDecl = nnkVarSection.newTree()
      componentsToRemove: set[uint16]
      # TODO: Could use the system ground truth to determine the number of components we need to
      # remove from the component list.
      # ie; `if aFound: numComponentsToRemove += 1` etc.
      # This would mean we wouldn't keep searching the component list for, say, owned components
      # as we know how many to look for, especially as we've already determined whether the system
      # is populated.
      numComponentsToRemove = 1

    # Always remove parameter component to removeComponent.
    componentsToRemove.incl typeId.uint16
    
    for systemIndex in relevantSystems:
      if not visited[systemIndex.int]:
        visited[systemIndex.int] = true
        # We must remove all references to every relevant system here,
        # as we're removing a required component for the system to run.
        let
          sysOpts = ecsSysOptions[systemIndex.int]
          sysName = sysOpts.name
          sysIdent = ident systemVarName(sysName)
          foundSys = ident sysName.toLower & "Found"
          foundSysRow = ident sysName.toLower & "FoundRow"
          userSysRemove = userRemoveCode(systemIndex.int, sysIdent, foundSysRow, entityIdIdent, entityIdent, sysOpts)
          sysNode = allSystemsNode[systemIndex.int]
          tryGetIndex = sysNode.indexTryGet(entityIdIdent, rowIdent, sysOpts)
        
        foundDecl.add newIdentDefs(foundSys, ident "bool")
        foundDecl.add newIdentDefs(foundSysRow, ident "int")
        if typeId.uint16 notin componentsToRemove:
          numComponentsToRemove += 1
        componentsToRemove.incl typeId.uint16

        findSysCode.add(quote do:
          if `tryGetIndex`:
            `foundSys` = true
            `foundSysRow` = `rowIdent`
          )
        updateSystems.add(removeSysReference(systemIndex.int, sysIdent, foundSys, foundSysRow, entityIdIdent, entityIdent, sysOpts))

        # When removing a component that's also part of an owned system, we must also remove any owned components
        # for that system, since we are effectively invalidating the owned component's storage.
        for ownedComp in systemOwnedComponents[systemIndex.int]:
          if ownedComp != typeId:
            # Increment search counter to include owned components.
            if ownedComp.uint16 notin componentsToRemove:
              numComponentsToRemove += 1
            componentsToRemove.incl ownedComp.uint16

        # Add user remove code.
        if componentSystemOwner[typeId.int] == systemIndex and typeId.int < componentRemoveCode.len:
          let compRem = componentRemoveCode[typeId.int]
          if compRem != nil:
            userSysRemove.add(quote do:
              template curComponent: untyped = `typeInstanceIdent`(`foundSysRow`)
              `compRem`
            )

        if userSysRemove.len > 0:
          userUpdates.add(quote do:
            if `foundSys`:
              `userSysRemove`
          )

    var removeRefCore = newStmtList()
    let
      compsDeleted = ident "compsDeleted"
      delCompCount = newLit numComponentsToRemove
    
    var compIdx = 0
    for delComp in componentsToRemove:

      let
        typeName = tNames[delComp.int]
        delInstanceType = ident instanceTypeName(typeName)
      var
        userCompRemove = newStmtList()
        updateOwnedAliveState = newStmtList()

      if delComp.int < componentRemoveCode.len:
        let compRem = componentRemoveCode[delComp.int]
        if compRem != nil:
          #if componentSystemOwner[delComp.int] == InvalidSystemIndex:
          userCompRemove.add(quote do:
            template curComponent: untyped = `delInstanceType`(`foundComp`.index)
            `compRem`
          )

      if componentSystemOwner[delComp.int] != InvalidSystemIndex:
        # Update alive state.
        let aliveIdent = ident aliveStateInstanceName(typeName)
        updateOwnedAliveState.add(quote do:
          `aliveIdent`[`foundComp`.index.int] = false
        )

      # TODO: Multiple owned components may need to be removed from entity's component list.

      let
        removeCompFromEntity = removeComponentRef(entityIdIdent, removeIdxIdent, delComp.int, entOpts)

        coreDelete = quote do:
          `userCompRemove`
          `tyDelete`(`delInstanceType`(`foundComp`.index))
          `removeCompFromEntity`
          `updateOwnedAliveState`
        
      if entOpts.componentStorageFormat == csTable:
        removeRefCore.add(quote do:
          `foundComp` = entityData(`entityIdIdent`).componentRefs.getOrDefault(`delComp`.ComponentTypeId)
          if `foundComp`.typeId == `delComp`.ComponentTypeId:
            `coreDelete`
          )
      else:
        removeRefCore.add(quote do:
          `foundComp` = entityData(`entityIdIdent`).componentRefs[`removeIdxIdent`]
          if `foundComp`.typeId == `delComp`.ComponentTypeId:
            `coreDelete`
            `compsDeleted` = `compsDeleted` + 1
            if `compsDeleted` == `delCompCount`:
              break
            `removeIdxIdent` = `removeIdxIdent` - 1
            continue
        )
      compIdx += 1

    let removeRef =
      case entOpts.componentStorageFormat
      of csTable:
        quote do:
          var `foundComp`: ComponentRef
          `removeRefCore`
      of csSeq, csArray:
        quote do:
          var
            `foundComp`: ComponentRef
            `removeIdxIdent` = `componentLen` - 1
            `compsDeleted` = 0
          while `removeIdxIdent` >= 0:
            `removeRefCore`
            `removeIdxIdent` = `removeIdxIdent` - 1

    let
      setVal = ident "ce" & typeName
      setOp = entSetExcl(entOpts, entityIdIdent, setVal)
      doRemoveName = ident "doRemove" & typeName

    result.add(quote do:
      proc `doRemoveName`(`entityIdent`: EntityRef) =
        assert `entityIdent`.`alive`
        let `entityIdIdent` = `entityIdent`.entityId

        if entityData(`entityIdIdent`).setup:
          ## Access to currently updating entity.
          template curEntity: untyped {.used.} = `entityIdent`
          # RowIdent is used by updateSystems.
          var `rowIdent` {.used.}: int
          `foundDecl`
          `findSysCode`
          `userUpdates`
          # Update set if required.
          `setOp`
          `removeRef`
          # Remove this entity from all relevant systems.
          `updateSystems`
            
      template removeComponent*(`entityIdent`: EntityRef, compType: `compTypedesc`) =
        ## Remove the component.
        static:
          if inSystemAll and inSystemIndex in `relevantSystems`:
            # Calling removeComponent from within a system that uses the component.
            # We don't know if it's the current row's entity or some other entity.
            sysRemoveAffectedThisSystem = true
        `doRemoveName`(`entityIdent`)
    )
  genLog "# Remove component:\n", result.repr

proc clearAllEntComponentRefs(entityId: NimNode, options: ECSEntityOptions): NimNode =
  case options.componentStorageFormat
  of csSeq:
    quote do:
      for compRef in entityData(`entityId`).componentRefs:
        caseComponent compRef.typeId:
          componentDel(componentInstanceType()(compRef.index))
      entityData(`entityId`).componentRefs.setLen(0)
  of csArray:
    quote do:
      for compIdx in 0 ..< entityData(`entityId`).nextCompIdx:
        let curCompRef = entityData(`entityId`).componentRefs[compIdx]
        caseComponent curCompRef.typeId:
          componentDel(componentInstanceType()(curCompRef.index))
      entityData(`entityId`).nextCompIdx = 0
  of csTable:
    quote do:
      for compPair in entityData(`entityId`).componentRefs.pairs:
        caseComponent compPair[1].typeId:
          componentDel(componentInstanceType()(compPair[1].index))
      entityData(`entityId`).componentRefs.clear

proc recyclerAdd(ecStateNode, entIdNode: NimNode, options: ECSEntityOptions): NimNode =
  case options.recyclerFormat
  of rfSeq:
    quote do: `ecStateNode`.entityRecycler.add `entIdNode`
  of rfArray:
    let rLen = ident recyclerArrayLen()
    quote do:
      let nextIdx = `ecStateNode`.`rLen`
      assert nextIdx < `ecStateNode`.entityRecycler.len
      
      `ecStateNode`.entityRecycler[nextIdx] = `entIdNode`
      `ecStateNode`.`rLen` += 1

proc recyclerClear*(ecStateNode: NimNode, options: ECSEntityOptions): NimNode =
  case options.recyclerFormat
  of rfSeq:
    quote do: `ecStateNode`.entityRecycler.setLen 0
  of rfArray:
    let rLen = ident recyclerArrayLen()
    quote do:
      `ecStateNode`.`rLen` = 0

proc makeDelete*(options: ECSEntityOptions): NimNode =
  ## Generates delete procedures for the current entity.
  ## Delete will be created with all the systems that have been seen since the last
  ## `makeEcs` invocation.
  let
    ent = ident("entity")
    delProcName = ident("delete")
    compRefIdent = ident("compRef")
    allCompSystems = compSystems()
    storageVar = ident entityStorageVarName()
    totalSystemCount = allSystemsNode.len
    rowIdent = ident "row"
    entIdIdent = ident "entityId"
    visitedIdent = ident "visited"
    clearComponents = clearAllEntComponentRefs(entIdIdent, options)
    foundDecls = nnkVarSection.newTree()
    foundChecks = newStmtList()
    visitedArray = quote do:
      var `visitedIdent`: array[0 .. `totalSystemCount`, bool]

  var
    updateSystems = newStmtList()
    caseStmtRemove = nnkCaseStmt.newTree()
    caseStmtUserCode = nnkCaseStmt.newTree()

  # Here we build a case statement executed for each of the entity's component indexes
  # so that each branch contains the appropriate free code for all systems that use
  # that component.
  # A system may have a requirement for multiple components that aren't satisfied though,
  # so we must also check if there's a row to be removed.
  caseStmtRemove.add newDotExpr(compRefIdent, ident "typeId")
  caseStmtUserCode.add newDotExpr(compRefIdent, ident "typeId")
  
  var
    includeEntityTmpl: bool
    processedSystems: set[int16]
    userCodeExists: bool

  for compId in ecsComponentsToBeSealed:
    let
      compIdx = compId.int
      compSystems = allCompSystems[compIdx]
      tyName = tNames[compIdx.int]
      tyInstance = newIdentNode instanceTypeName(tyName)

      # Retrieve list of systems that use this component.
      #compSystems = allCompSystems[compIdx]

    # User callback.
    var
      removeBody = newStmtList()
      userBody = newStmtList()

    # For each component, update any systems referenced.  
    for sysIdx in compSystems:
      # Process only new systems we haven't seen before for this set of entities.
      if sysIdx in ecsSystemsToBeSealed:
        let
          sysOpts = ecsSysOptions[sysIdx.int]
          sysNameUpper = systemNames[sysIdx.int].capitalizeAscii
          sysNameLower = systemNames[sysIdx.int].toLowerAscii
          sysIdent = ident systemVarName(sysNameUpper)
          sysNode = allSystemsNode[sysIdx.int]
          tryGetSys = sysNode.indexTryGet(entIdIdent, rowIdent, sysOpts)
          foundSys = ident sysNameLower & "Found"
          foundSysRow = ident sysNameLower & "Row"

          removeSystemEntry = removeSysReference(sysIdx.int, sysIdent, foundSys, foundSysRow, entIdIdent, ent, sysOpts)
          userSysRemove = userRemoveCode(sysIdx.int, sysIdent, foundSysRow, entIdIdent, ent, sysOpts)
        
        if sysIdx.int16 notin processedSystems:
          processedSystems.incl sysIdx.int16
          foundDecls.add newIdentDefs(foundSys, ident "bool")
          foundDecls.add newIdentDefs(foundSysRow, ident "int")
          foundChecks.add(quote do:
            if `tryGetSys`:
              `foundSys` = true
              `foundSysRow` = `rowIdent`
            )

        if componentSystemOwner[compIdx.int] == sysIdx:
          # Update alive state for owned components.
          let
            aliveIdent = ident aliveStateInstanceName(tyName)
            cIdx = compIdx.int
          updateSystems.add(quote do:
            `aliveIdent`[`cIdx`] = false
          )

        removeBody.add(
          quote do:
            if not `visitedIdent`[`sysIdx`]:
              `visitedIdent`[`sysIdx`] = true
              `removeSystemEntry`
        )

        if userSysRemove.len > 0:
          userBody.add(
            quote do:
              if not `visitedIdent`[`sysIdx`]:
                `visitedIdent`[`sysIdx`] = true
                if `foundSys`:
                  `userSysRemove`
          )

    # Remove code by component.
    if compIdx < componentRemoveCode.len:
      let compRem = componentRemoveCode[compIdx.int]
      if compRem != nil:
        includeEntityTmpl = true
        userBody.add(quote do:
          ## Current component being removed from entity. 
          template curComponent: untyped {.used.} = `tyInstance`(`compRefIdent`.index)
          `compRem`
        )
    
    if removeBody.len > 0:
      var ofNodeRemove = nnkOfBranch.newTree()
      ofNodeRemove.add newDotExpr(newIntLitNode(compIdx), ident"ComponentTypeId")
      ofNodeRemove.add newStmtList(removeBody)
      caseStmtRemove.add(ofNodeRemove)

    if compIdx.int < removeCallbackProcs.len:
      let removeCallback = removeCallbackProcs[compIdx.int]
      if removeCallback != nil:
        includeEntityTmpl = true
        let cbProcName = ident removeCallbackName(tyName)
        userBody.add(quote do:
          `cbProcName`(`ent`, `tyInstance`(`compRefIdent`.index)))

    if userBody.len > 0:
      userCodeExists = true
      var ofNodeUser = nnkOfBranch.newTree()
      ofNodeUser.add newDotExpr(newIntLitNode(compIdx), ident"ComponentTypeId")
      ofNodeUser.add newStmtList(userBody)
      caseStmtUserCode.add(ofNodeUser)

  caseStmtRemove.add nnkElse.newTree(newStmtList(quote do: discard))
  caseStmtUserCode.add nnkElse.newTree(newStmtList(quote do: discard))
  
  updateSystems.add caseStmtRemove

  let
    # For pointer arrays, the GC needs to be informed about the componentRef sequence.
    gcCleanup =
      case options.entityStorageFormat
      of esSeq, esArray: newEmptyNode()
      of esPtrArray:
        if options.componentStorageFormat in [csSeq, csTable]:
          quote do:
            GC_Unref(entityData(`entIdIdent`).componentRefs)
        else:
          newEmptyNode()
    recyclerAdd = storageVar.recyclerAdd(entIdIdent, options)
    recyclerClear = storageVar.recyclerClear(options)
    initSet =
      if options.useSet:
        quote do:
          entityData(`entIdIdent`).exists = {}        
      else: newEmptyNode()

  let
    clearRecycler = storageVar.recyclerClear(options)
    curEntTmpl =
      if includeEntityTmpl:
        quote do:
          ## Access to currently updating entity.
          template curEntity: untyped {.used.} = `ent`
      else: newEmptyNode()
    userCode =
      if userCodeExists:
        quote do:
          block:
            `visitedArray`
            for `compRefIdent` in `entIdIdent`.components:
              `caseStmtUserCode`
      else: newStmtList()

  result = quote do:
    proc doDelete(`ent`: EntityRef) =

      if not `ent`.alive: return
      let `entIdIdent` = `ent`.entityId
      if entityData(`entIdIdent`).setup:
        var `rowIdent`: int

        `foundDecls`
        `foundChecks`
        `curEntTmpl`
        `userCode`
        # finally, clear components.
        # We don't bother calling removeComponentRef here because we're deleting all of the components and don't need them reshuffled.
        `visitedArray`
        for `compRefIdent` in `entIdIdent`.components:
          `caseStmtRemove`
        `initSet`
        `clearComponents`
        `gcCleanup`

        entityData(`entIdIdent`).setup = false
        `storageVar`.entityCounter -= 1
        `recyclerAdd`

        if `storageVar`.entityCounter == 0:
          # Helps against nextEntityId going out of range after repeated add/delete.
          `recyclerClear`
          `storageVar`.nextEntityId = FIRST_ENTITY_ID

    template `delProcName`*(`ent`: EntityRef) =
      static:
        if inSystem and (not inSystemDeleteRow): systemCalledDelete = true
      doDelete(`ent`)

    proc deleteAll*(entities: Entities) =
      for i in 0 ..< entities.len:
        entities[i].delete

    proc resetEntityStorage* =
      ## This deletes all entities, removes them from associated systems and resets next entity.
      # TODO: More efficient to dispense with the book keeping and just clear systems & storage manually.
      # Good for testing for issues with delete though.
      # NOTE: ENTITY INSTANCE FIELD SHOULD REMAIN INTACT!
      for i in 0 ..< `storageVar`.nextEntityId.int:
        let ent = (i.EntityId).makeRef
        ent.delete
      `clearRecycler`
      `storageVar`.nextEntityId = FIRST_ENTITY_ID
      `storageVar`.entityCounter = 0

  genLog "# Delete entity:\n", result.repr

