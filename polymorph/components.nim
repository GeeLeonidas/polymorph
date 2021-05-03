# SPDX-License-Identifier: Apache-2.0

# Copyright (c) 2020 Ryan Lipscombe
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import macros, strformat, sharedtypes, private/[utils, ecsstatedb], strutils
import macrocache
export macros

macro componentNames*(id: static[EcsIdentity]): untyped =
  ## Creates a runtime accessible array of typenames of all known components.
  ## This should map directly to componentTypeId.
  var comps = nnkBracket.newTree
  for i in 0 ..< id.components.len:
    comps.add newLit id.typeName(i.ComponentTypeId)
  result = quote do:
    @`comps`

proc addComponentTypeId(id: EcsIdentity, typeNameStr: string): ComponentTypeId {.compileTime.} = 
  result = id.addTypeId typeNameStr

  id.set_instanceType(result, instanceTypeName typeNameStr)
  id.set_refType(result, refTypeName typeNameStr)
  
  genLog "# Added component type: \"", typeNameStr, "\" = ", $result.int

## Checks against invalid component (for example uninitialised data).
## This does not check to see if the component is alive in the system, only that it is semantically valid.
## Used for example to check that fetchComponent has found its value.
proc valid*(compRef: ComponentRef): bool = compRef.typeId != InvalidComponent and compRef.generation.int != InvalidComponentGeneration.int

proc contains*(compRefs: ComponentList, typeId: ComponentTypeId): bool {.inline.} =
  ## Linear search through `compRefs` for `typeId`.
  for item in compRefs:
    if item.fTypeId == typeId: return true

proc findTypeId*(compRefs: ComponentList, typeId: ComponentTypeId): int =
  for i in 0 ..< compRefs.len:
    if compRefs[i].fTypeId == typeId: return i

## Read only access to the type id inside a Component descendant
proc typeId*[T: Component](c: T): ComponentTypeId = c.fTypeId

func init*[T: Component](c: var T) {.inline.} =
  ## Useful when storing in containers, eg; seq[Component]
  c.fTypeId = c.type.typeId()
  assert c.fTypeId != InvalidComponent

proc checkInit*[T: Component](c: var T) {.inline.} =
  if c.fTypeId.int == 0: c.fTypeId = c.type.typeId()

proc makeRefCompInit(prefix: string, tyName: string, typeId: int): NimNode =
  # Generate init macro for reference type.
  # This macro curries the parameters to an object initialisation of the form `MyObjectRef(param1: value1, ...)`.
  let
    tyNameRefStr = refTypeName(tyName)
    initNameStr = refInitName(prefix, tyName)
    initName = newIdentNode(initNameStr)
    initComment = newCommentStmtNode("Initialiser for " & tyNameRefStr & ", automatically sets `typeId` to " & $typeId)
    res = newIdentNode "result"
    typeIdFieldName = "fTypeId"

  result = quote do:
    macro `initName`*(args: varargs[untyped]): untyped =
      `initComment`

      # Setup value object that stores the component data.
      var
        stmts = newStmtList()
        objData = nnkObjConstr.newTree()

      objData.add newIdentNode(`tyName`)

      # update the value object's fields.
      for arg in args:
        if arg.kind notin {nnkExprEqExpr, nnkExprColonExpr}:
          error("Expected an equals or colon assignment but got " & $arg.kind)
        # Assign this data item to the value object's field.
        objData.add nnkExprColonExpr.newTree(arg[0], arg[1])
    
      # build the ref object type constructor 
      stmts.add(nnkObjConstr.newTree(
        newIdentNode `tyNameRefStr`,
        nnkExprColonExpr.newTree(
          newIdentNode(`typeIdFieldName`),
          newDotExpr(newIntLitNode(`typeId`), newIdentNode("ComponentTypeId"))
        ),
        nnkExprColonExpr.newTree(
          newIdentNode("value"), objData
        )
        ))

      `res` = stmts

proc makeInstanceCompInit(prefix, tyName: string, typeId: int): NimNode =
  ## This macro generates an init proc that allows setting of fields.
  ## These init procs return the instance of the type, which allows direct field access
  ## and can be converted to a ref with toRef().
  ## Eg;
  ##   let comp = newMyComponent(x = 1, y = 2)
  ## Translates to something like this:
  ##   var comp = MyComponent(typeId: MyComponent.typeId, x: 1, y: 2)
  let
    initInstanceStr = instanceInitName(prefix, tyName)
    initInstance = newIdentNode(initInstanceStr)
    initComment = newCommentStmtNode("Initialiser for " & tyName & "(`typeId` " & $typeId & ")")
    res = newIdentNode "result"

  result = quote do:
    macro `initInstance`*(args: varargs[untyped]): untyped =
      `initComment`
      # Create value object that stores the component data and pass assignments from parameters.
      # Code produced is essentially 
      
      var
        stmts = newStmtList()
        newComp = genSym(nskLet, "newComp")

      # generate new component instance for this type:
      # (This is defined below after storage has been instantiated)
      # eg;
      #   let newComp = `initProc`()
      stmts.add(
        nnkLetSection.newTree(
          nnkIdentDefs.newTree(
            newComp,
            newEmptyNode(),
            nnkCall.newTree(
              newIdentNode createInstanceName(`tyName`)
            )
          )
        )
      )
      
      var objData = nnkObjConstr.newTree()
      objData.add newIdentNode(`tyName`)

      # update the value object's fields.
      for arg in args:
        if arg.kind notin {nnkExprEqExpr, nnkExprColonExpr}:
          error("Expected an equals or colon assignment but got " & $arg.kind)
        # Assign this data item to the value object's field.
        objData.add nnkExprColonExpr.newTree(arg[0], arg[1])

      stmts.add(nnkCall.newTree(nnkDotExpr.newTree(newComp, newIdentNode("update")), objData))

      # The return expression is the instance type of the new component.
      stmts.add newComp

      # build the type constructor
      `res` = nnkBlockStmt.newTree(
        newEmptyNode(), stmts)

proc nameNode(typeNode: NimNode): NimNode =
  typeNode.expectKind nnkTypeDef
  typeNode[0].baseName

proc createRefComponent(typeName: string): NimNode =
  # Creates a type inherited from `Component` that contains the fields for this type.
  # This is used for runtime templates, allowing heterogeneous list of components.
  # eg:
  #  ComponentTypeRef* = ref object of Component
  #    value*: ComponentType
  let
    refName = ident refTypeName(typeName)
    typeIdent = ident typeName
    value = ident "value"
  quote do:
    type `refName`* = ref object of Component
      `value`*: `typeIdent`

proc doRegisterComponents(id: EcsIdentity, options: ECSCompOptions, body: NimNode): NimNode =
  ## Registers types in a block as components.
  ## For each type provided in `body`, this macro generates:
  ##   * A ref container for the type with a typeId field for use in runtime templates.
  ##   * A static template to associate the type with a unique `ComponentTypeId`.
  ##   * An initialiser for use with runtime templates. This sets the type Id for you.
  ## The types sections you provide in `body` are passed through unaltered.

  result = newStmtList()

  var
    typeDeclarations = newStmtList()
    typeUtils = newStmtList()
    registered: seq[string]
  let previousComponentsDeclared = id.components.len

  for tyDef in body.typeDefs:
    
    # Handle {.notComponent.} for simplifying ad hoc types used
    # inside registerComponents.
    const
      notComponentStr = "notComponent"
      pragExpr = 0
      pragmaList = 1

    var notComponent = -1
    
    if tyDef[pragExpr].kind == nnkPragmaExpr:
      tyDef[pragExpr].expectMinLen 2
      let pragma = tyDef[pragExpr][pragmaList]
      pragma.expectKind nnkPragma
      if pragma.len > 0:
        for i in 0 ..< pragma.len:
          if pragma[i].kind == nnkIdent and pragma[i].strVal == notComponentStr:
            notComponent = i
            break

      if notComponent > -1:
        # Remove {.notComponent.} from typeDef and ignore.
        pragma.del(notComponent)
        if pragma.len == 0:
          # Remove empty pragma declaration and transpose ident.
          let pragmaIdent = 0
          tyDef[pragExpr] = tyDef[pragExpr][pragmaIdent]
        continue

    let
      typeNameIdent = tyDef.nameNode()
      typeNameStr = $typeNameIdent
      # store compInfo for component type and generate id
      typeId = id.addComponentTypeId(typeNameStr)
      instTypeNode = newIdentNode instanceTypeName(typeNameStr)
      generationTypeNode = newIdentNode generationTypeName(typeNameStr)
      typeIdAccessName = newIdentNode("typeId")
      tyParam = newIdentNode("ty")
      refTypeNameIdent = newIdentNode(refTypeName(typeNameStr))
    
    registered.add typeNameStr

    # Update the build list.
    id.add_ecsComponentsToBeSealed typeId
    
    # Record the options for later transforms such as commitSystems
    id.setOptions(typeId, options)

    typeUtils.add typeNameStr.createRefComponent

    typeDeclarations.add(quote do:
      type `instTypeNode`* = distinct `IdBaseType`
      type `generationTypeNode`* = distinct `IdBaseType`
    )
    # Add static transform to convert from type to `ComponentTypeId`
    # eg; template typeId*(ty: A | ARef | AInstance): ComponentTypeId = 1.ComponentTypeId
    # The same value is returned for a concrete instance, ref instance, and typedesc.
    typeUtils.add(quote do:
      template `typeIdAccessName`*(`tyParam`: `typeNameIdent` | `refTypeNameIdent` | `instTypeNode` |
        typedesc[`typeNameIdent`] | typedesc[`refTypeNameIdent`] | typedesc[`instTypeNode`]): ComponentTypeId = `typeId`.ComponentTypeId
      )

  if id.components.len == previousComponentsDeclared:
    error "Cannot process registerComponents: No typeDefs can be found to create components from"
  
  if options.componentStorageFormat != cisSeq and options.maxComponents <= 0:
    error "Component option `maxComponents` must be greater than zero when using a non-resizable storage format"

  when defined(ecsLog) or defined(ecsLogDetails):
    echo  "[ Component generation ]\n",
          "Registered: ", registered.join(", ")
  when defined(ecsLogDetails):
    echo "Component options:\n", options.repr, "\n"

  # Generate the storage array type for these components
  # storageTypeName: object =
  #   <fields of type>
  result.add typeDeclarations
  # The body always gets added unchanged, but after the instance types have been generated.
  # This allows instance types to be used within the user's type definitions.
  result.add body
  result.add typeUtils

  genLog("\n# Register components:\n" & result.repr)  

proc generateTypeStorage*(id: EcsIdentity): NimNode =
  result = newStmtList()

  var
    typeUtils = newStmtList()
    # Each component gets a unique array generated in the storage type.
    storageFields = nnkVarSection.newTree()
  
  for typeId in id.unsealedComponents:
    
    let
      options = id.getOptions(typeId)
      typeNameStr = id.typeName typeId
      typeNameIdent = ident typeNameStr
      refTypeNameIdent = newIdentNode(refTypeName(typeNameStr))
      tyParam = newIdentNode("ty")

      maxComponentCount = options.maxComponents + 2
      refInitPrefix = if options.refInitPrefix != "": options.refInitPrefix
        else: defaultRefInitPrefix

    let instTypeNode = newIdentNode instanceTypeName(typeNameStr)
    
    # Add initialiser proc that sets `typeId` and passes on params to an object constructor.
    # eg; initA*(param = x): A = A(fTypeId: A.typeId, param: x)
    typeUtils.add makeRefCompInit(refInitPrefix, typeNameStr, typeId.int)
    
    typeUtils.add(quote do:
      ## Compile-time translation between a user's type/container type to its instance type.
      ## Useful for converting a ComponentIndex into direct storage access.
      template instanceType*(`tyParam`: typedesc[`typeNameIdent`] | typedesc[`refTypeNameIdent`]): untyped = `instTypeNode`
      ## Compile-time translation between a user's type to its container `ref` type.
      template containerType*(`tyParam`: typedesc[`typeNameIdent`] | typedesc[`instTypeNode`]): untyped = `refTypeNameIdent`
      ## Create a `ref` container from a user object.
      template makeContainer*(`tyParam`: `typeNameIdent`): `refTypeNameIdent` =
        var container = `refTypeNameIdent`(fTypeId: `typeId`.ComponentTypeId, value: `tyParam`)
        container
      ## Create a `ref` container from an instance.
      template makeContainer*(`tyParam`: `instTypeNode`): `refTypeNameIdent` =
        `tyParam`.access.makeContainer()
      )

    let storageFieldName = typeNameStr.storageFieldName

    proc storageField(typeIdent: NimNode, maxComps: int): NimNode =
      case options.componentStorageFormat
        of cisArray: genArray(maxComps, typeIdent)
        of cisSeq: genSeq(typeIdent)

    let
      useThreadVar = options.useThreadVar
      ownerSystem = id.systemOwner typeId
      
      supportStorageSize =
        if ownerSystem == InvalidSystemIndex:
          maxComponentCount + 1
        else:
          let format = id.storageFormat(ownerSystem)
      
          if format == ssArray:
            # For arrays, owned systems must be set to the maximum number of entities.
            let maxEnts = id.maxEntities(ownerSystem) + 1
            id.set_maxEntities(ownerSystem, maxEnts)

            maxEnts
          else:
            0

    # Generate the field that will hold this component within storage.
    # eg; a: array[100000, A]
    # Note: Currently this field has to be added unconditionally as we don't know if this component is owned yet.
    storageFields.add genField(storageFieldName, true, typeNameIdent.storageField(supportStorageSize), useThreadVar)
    
    # Generate the last index list for this component of the specific instance type
    # eg; aLastIndex: seq[AInstance]
    let freeIdxIdent = typeNameStr.freeInstancesName
    storageFields.add genField(freeIdxIdent, true, genSeq(instTypeNode), useThreadVar)
    
    # Generate the next index variable for this component
    # eg; aNextIndex: AInstance
    let nextIdxName = typeNameStr.nextInstanceName
    storageFields.add genField(nextIdxName, true, instTypeNode, useThreadVar)

    # Generate the instance alive state array for this component type
    # eg; aAlive: array[100000, bool]
    let aliveStateIdent = typeNameStr.aliveStateInstanceName
    storageFields.add genField(aliveStateIdent, true, newIdentNode("bool").storageField(supportStorageSize), useThreadVar)

    # Generate an array of instance numbers against each component id
    # This allows us to compare an existing instance with a ComponentRef.
    let instanceIdsName = typeNameStr.instanceIdsName
    storageFields.add genField(instanceIdsName, true, newIdentNode("int32").storageField(supportStorageSize), useThreadVar)

  result.add storageFields
  result.add typeUtils
  genLog("\n# Component type storage:\n" & result.repr)

proc genTypeAccess*(id: EcsIdentity): NimNode =
  result = newStmtList()  
  
  var
    typeAccess = newStmtList()
    firstCompIdInits = newStmtList()
  let
    identity = quote do: EcsIdentity(`id`)

  for typeId in id.unsealedComponents:
    let
      options = id.getOptions typeId
      initPrefix = if options.initPrefix != "": options.initPrefix else: defaultInitPrefix
      maxComponentCount = options.maxComponents + 2
      typeNameStr = id.typeName typeId
      typeNameIdent = ident typeNameStr
      storageFieldName = storageFieldName(typeNameStr)
      lcTypeIdent = newIdentNode storageFieldName                   # Variable holding the component's data, indexed by ComponentIndex.
      createIdent = newIdentNode createInstanceName(typeNameStr)    # Proc to create a storage entry and return the ComponentIndex.
      deleteIdent = newIdentNode deleteInstanceName()               # Proc to remove a storage entry by ComponentIndex.
      freeIdxIdent = newIdentNode freeInstancesName(typeNameStr)    # Variable holding a stack of free indexes.
      instParam = ident "instance"
      instanceIds = newIdentNode instanceIdsName(typeNameStr)       # Variable holding the generation of indexes.
      instanceTypeIdent = ident instanceTypeName(typeNameStr)
      refTypeNameIdent = newIdentNode id.refType(typeId)            # Ref container type
      aliveIdent = newIdentNode aliveStateInstanceName(typeNameStr)
      nextIdxIdent = newIdentNode nextInstanceName(typeNameStr)
      tyParam = ident "ty"
      instTypeName = id.instanceType typeId
      instTypeNode = newIdentNode instTypeName                  # Type's instance type
      generationTypeNode = newIdentNode generationTypeName(typeNameStr)
      invalidFieldPrefix = newLit "undeclared field: '"
      invalidFieldPostfix = "' for component type " & typeNameStr
      perfRead =
        when defined(ecsPerformanceHints): quote do:
          static:
            if `identity`.inSystem:

              `identity`.add_readsFrom `identity`.inSystemIndex, `typeId`.ComponentTypeId
        else: newStmtList()
      perfWrite =
        when defined(ecsPerformanceHints): quote do:
          static:
            if `identity`.inSystem:
              `identity`.add_writesTo `identity`.inSystemIndex, `typeId`.ComponentTypeId
        else: newStmtList()

    # Add a proc to return a new component index.
    # This is the 'new component' procedure, and uses the `initPrefix` parameters.
    typeAccess.add(makeInstanceCompInit(initPrefix, typeNameStr, typeId.int))
    
    # Potentially extra init for heap items
    case options.componentStorageFormat
      of cisArray:
        # No init needed for array types.
        discard
      of cisSeq:
        firstCompIdInits.add(quote do:
          `lcTypeIdent`.setLen 1
          `aliveIdent`.setLen 1
          `instanceIds`.setLen 1
        )

    # Ensure first component item is valid.
    firstCompIdInits.add(quote do:
      `nextIdxIdent` = FIRST_COMPONENT_ID.`instanceTypeIdent`
    )

    let
      eqOp = nnkAccQuoted.newTree(newIdentNode "==")
      onInterceptValueInitCode = id.onInterceptValueInitCodeNode(typeId)
      userInterceptInitCode =
        if onInterceptValueInitCode.len > 0:
          # It's now the user's responsibility to call update to pass
          # on the initial parameters.
          onInterceptValueInitCode
        else:
          newEmptyNode()
      #
      commitParam = ident "newValue"
      valueParam = ident "value"
      inst = ident "instance"
      fieldParam = ident "field"
      #
      invalidAccessCheck =
        case id.invalidAccess(typeId)
        of iaAssert:
          quote do:
            assert `inst`.valid, "Access on an invalid component"
        of iaIgnore:
          newStmtList()
      sysOwner = id.systemOwner(typeId)

    if sysOwner != InvalidSystemIndex:
      # This component is owned by a system, so access templates need to
      # directly reference the owner system.
      let
        ownerSystem = id.instantiation sysOwner
        sysTupleFieldStr = typeNameStr.toLowerAscii
        sysTupleField = ident sysTupleFieldStr
        standAloneUpdate =
          if userInterceptInitCode.len > 0:
            quote do:
              block:
                template commit(`commitParam`: `typeNameIdent`): untyped =
                  `ownerSystem`.groups[`inst`.int].`sysTupleField` = `commitParam`
                template curValue: `typeNameIdent` = `valueParam`
                `userInterceptInitCode`
          else:
            quote do:
              `ownerSystem`.groups[`inst`.int].`sysTupleField` = `valueParam`

      # Dot overload to access the fields of the component in the owner system via the index.
      # Two approaches, via dot operators or building access templates for every field in this component (not recursive).
      case options.accessMethod
      of amDotOp:
        # We only need two dot operators, one for reading and one for writing to cover all the fields in this instance.
        {.push experimental: "dotOperators".}
        let
          dotOp = nnkAccQuoted.newTree(newIdentNode ".")
          dotEqOp = nnkAccQuoted.newTree(newIdentNode ".=")

        typeAccess.add(quote do:
          template `dotOp`*(`inst`: `instanceTypeIdent`, `fieldParam`: untyped): untyped =
            when compiles(`ownerSystem`.groups[`inst`.int].`sysTupleField`.`fieldParam`):
              `invalidAccessCheck`
              `perfRead`
              `ownerSystem`.groups[`inst`.int].`sysTupleField`.`fieldParam`
            else:
              {.fatal: `invalidFieldPrefix` & astToStr(`fieldParam`) & `invalidFieldPostfix`.}
          template `dotEqOp`*(`inst`: `instanceTypeIdent`, `fieldParam`: untyped, `valueParam`: untyped): untyped =
            when compiles(`ownerSystem`.groups[`inst`.int].`sysTupleField`.`fieldParam`):
              `invalidAccessCheck`
              `perfWrite`
              `ownerSystem`.groups[`inst`.int].`sysTupleField`.`fieldParam` = `valueParam`
            else:
              {.fatal: `invalidFieldPrefix` & astToStr(`fieldParam`) & `invalidFieldPostfix`.}
        )
        {.pop.}

      typeAccess.add(quote do:
        template isOwnedComponent*(value: typedesc[`instanceTypeIdent`] | `instanceTypeIdent` | `typeNameIdent`): bool = true
        template valid*(`inst`: `instanceTypeIdent`): bool =
          # TODO: Check generation.
          `inst`.int >= 0 and `inst`.int < `ownerSystem`.groups.len
        ## Converts the instance to a component storage directly.
        template access*(`inst`: `instanceTypeIdent`): `typeNameIdent` = `ownerSystem`.groups[`inst`.int].`sysTupleField`
        template alive*(inst: `instTypeNode`): bool =
          ## Check if this component ref's index is still valid.
          `aliveIdent`[inst.int] == true
        template generation*(inst: `instTypeNode`): untyped =
          ## Access the generation of this component.
          `generationTypeNode`(`instanceIds`[inst.int]).ComponentGeneration
        template `createIdent` = discard
        template `deleteIdent`*(`instParam`: `instanceTypeIdent`) = discard
        
        # Updating storage.
        ## `update` operates as a simple assignment into the storage array and therefore operates on the type's `==` proc.
        template update*(`instParam`: `instanceTypeIdent`, `valueParam`: `typeNameIdent`): untyped =
          `standAloneUpdate`
        template componentCount*(value: typedesc[`instanceTypeIdent`] | `instanceTypeIdent` | `typeNameIdent`): int = `ownerSystem`.count
        ## Allows access to the owning system's `groups` field that stores components of this type.
        template componentStorage*(value: typedesc[`instanceTypeIdent`] | `instanceTypeIdent` | `typeNameIdent`): untyped = `ownerSystem`.groups
        template ownerSystemIndex*(value: typedesc[`instanceTypeIdent`] | `instanceTypeIdent` | `typeNameIdent`): untyped = `sysOwner`.SystemIndex
        template ownerSystem*(value: typedesc[`instanceTypeIdent`] | `instanceTypeIdent` | `typeNameIdent`): untyped = `ownerSystem`
      )

    else:
      # Non-owned component.

      let
        standAloneUpdate =
          if userInterceptInitCode.len > 0:
            quote do:
              block:
                template commit(`commitParam`: `typeNameIdent`): untyped {.used.} =         
                  `lcTypeIdent`[`instParam`.int] = `commitParam`
                template curValue: `typeNameIdent` = `valueParam`
                `userInterceptInitCode`
          else:
            quote do:
              `lcTypeIdent`[`instParam`.int] = `valueParam`

      # Dot overload to access the fields of the component in the storage list via the index.
      # Two approaches, via dot operators or building access templates for every field in this component (not recursive).
      case options.accessMethod
      of amDotOp:
        # We only need two dot operators, one for reading and one for writing to cover all the fields in this instance.
        {.push experimental: "dotOperators".}
        let
          dotOp = nnkAccQuoted.newTree(newIdentNode ".")
          dotEqOp = nnkAccQuoted.newTree(newIdentNode ".=")

        typeAccess.add(quote do:
          template `dotOp`*(`inst`: `instanceTypeIdent`, `fieldParam`: untyped): untyped =
            when compiles(`lcTypeIdent`[`inst`.int].`fieldParam`):
              `invalidAccessCheck`
              `perfRead`
              `lcTypeIdent`[`inst`.int].`fieldParam`
            else:
              {.fatal: `invalidFieldPrefix` & astToStr(`fieldParam`) & `invalidFieldPostfix`.}
          template `dotEqOp`*(`inst`: `instanceTypeIdent`, `fieldParam`: untyped, `valueParam`: untyped): untyped =
            when compiles(`lcTypeIdent`[`inst`.int].`fieldParam`):
              `invalidAccessCheck`
              `perfWrite`
              `lcTypeIdent`[`inst`.int].`fieldParam` = `valueParam`
            else:
              {.fatal: `invalidFieldPrefix` & astToStr(`fieldParam`) & `invalidFieldPostfix`.}
        )
        {.pop.}

      typeAccess.add(quote do:
        ## Converts the instance to a component storage directly.
        template isOwnedComponent*(value: typedesc[`instanceTypeIdent`] | `instanceTypeIdent` | `typeNameIdent`): bool = false
        template access*(instance: `instanceTypeIdent`): `typeNameIdent` = `lcTypeIdent`[instance.int]
        template alive*(inst: `instTypeNode`): bool =
          ## Check if this component ref's index is still in use.
          inst.int > 0 and inst.int < `aliveIdent`.len and `aliveIdent`[inst.int] == true
        template valid*(inst: `instanceTypeIdent`): bool = inst.int != InvalidComponentIndex.int
        template generation*(inst: `instTypeNode`): untyped =
          ## Access the generation of this component.
          `generationTypeNode`(`instanceIds`[inst.int]).ComponentGeneration
        ## Allows access to the base storage container that stores all components of this type.
        template componentStorage*(value: typedesc[`instanceTypeIdent`] | `instanceTypeIdent` | `typeNameIdent`): untyped = `lcTypeIdent`
        template ownerSystemIndex*(value: typedesc[`instanceTypeIdent`] | `instanceTypeIdent` | `typeNameIdent`): untyped = InvalidSystemIndex
      )

      let
        # delIdx is the index of the component in its storage.
        delIdx = ident "idx"
        storageHigh = newDotExpr(lcTypeIdent, ident "high")
        freeIdxLen = quote do: `freeIdxIdent`.len
        freeIdxPop = quote do: `freeIdxIdent`.pop

      # This is expected to return the typed index for the new component.
      let handleNextStorageItem =
        case options.componentStorageFormat
        of cisArray:
          quote do:
            let cur = `nextIdxIdent`
            assert `nextIdxIdent`.int < `maxComponentCount`, "Ran out of space to store this component (max slot index: " &
              $(`maxComponentCount` - 1) & ", asked for " & $(`nextIdxIdent`.int) & ")"
            `nextIdxIdent` = (`nextIdxIdent`.int + 1).`instanceTypeIdent`
            cur
        of cisSeq:
          quote do:
            let newLen = `lcTypeIdent`.len + 1
            `lcTypeIdent`.setLen(newLen)
            `instanceIds`.setLen(newLen)
            `aliveIdent`.setLen(newLen)
            `lcTypeIdent`.high.`instanceTypeIdent`

      # Remove `delIdx` from the component array.
      let handleDelStorageItem =
        case options.componentStorageFormat
        of cisArray:
          quote do:
            # We need to subtract the length by one because the first item starts at one.
            if `freeIdxIdent`.len == `storageHigh` - 1:
              # If the free list is full, everything's free so we can reset the list.
              `freeIdxIdent`.setLen 0
            else:
              `freeIdxIdent`.add `delIdx`.`instanceTypeIdent`
        of cisSeq:
          quote do:
            # We don't need nextIdxIdent as this is naturally managed by seq.len
            # TODO: Store the 2nd highest value when deleting a component to avoid wasted space.
            if `delIdx` == `lcTypeIdent`.high:
              let newLen = max(1, `lcTypeIdent`.len - 1)
              `lcTypeIdent`.setLen(newLen)
              `instanceIds`.setLen(newLen)
              `aliveIdent`.setLen(newLen)
            elif `freeIdxIdent`.high == `lcTypeIdent`.high:
              # Shrink seqs and update next index var.
              # We need to reserve index zero for invalid component.
              # The free list is full, everything is free so we can reset the list.
              `freeIdxIdent`.setLen(0)
              # TODO: Update other lists?
            else:
              # Add to free indexes.
              `freeIdxIdent`.add `delIdx`.`instanceTypeIdent`

      let
        componentLen =
          case options.componentStorageFormat
          of cisArray:
            quote do:
              `nextIdxIdent`.int - 1
          of cisSeq:
            quote do:
              `lcTypeIdent`.len

      let
        res = ident "result"
        onInitCode = id.onInitCodeNode(typeId)
        onFinalisationCode = id.onFinalisationCodeNode(typeId)
        userInterceptInitCode = id.onInterceptValueInitCodeNode(typeId)

        clearOnDelete =
          if options.clearAfterDelete:
            quote do:
              zeroMem(`instParam`.access.addr, `typeNameIdent`.sizeOf)
          else:
            newEmptyNode()
        userInitCode =
          if onInitCode != nil:
            let code = onInitCode
            quote do:
              block:
                template curComponent: `instanceTypeIdent` {.used.} = `res`
                `code`
          else:
            newEmptyNode()
        userFinalCode =
          if onFinalisationCode != nil:
            let finalisationCode = onFinalisationCode
            quote do:
              template curComponent: untyped {.used.} = `instParam`
              `finalisationCode`
          else:
            newEmptyNode()
        
        rawCreate = quote do:
          var r: `instanceTypeIdent`
          if `freeIdxLen` > 0:
            # Use last spare index.
            r = `freeIdxPop`
          else:
            # Generate a new index.
            r = `handleNextStorageItem`
          assert r.int != 0
          # Update alive state.
          `aliveIdent`[r.int] = true
          # Update instance state.
          # This means the first valid index will start at one,
          # and an instance of zero can be used as an invalid state (see InvalidComponentRef)
          `instanceIds`[r.int] += 1
          assert r.int >= 0
          r

        newCompUpdate =
          if userInterceptInitCode.len > 0:
            quote do:
              template commit(`commitParam`: `typeNameIdent`): untyped =
                `lcTypeIdent`[`res`.int] = `commitParam`
              template curValue: `typeNameIdent` = `valueParam`
              `userInterceptInitCode`
          else:
            quote do:
              `lcTypeIdent`[`res`.int] = `valueParam`

      typeAccess.add(quote do:
        proc `createIdent`*: `instanceTypeIdent` =
          ## Create a component instance for this type.
          # This proc is generated for each type to use the separate storage locations.
          # This involves either popping an index from the component's free list or incrementing its next value counter,
          # then setting its alive index to true.
          `res` = `rawCreate`
          `userInitCode`
        proc `deleteIdent`*(`instParam`: `instanceTypeIdent`) =
          ## Free a component instance
          let `delIdx` = `instParam`.int
          assert `delIdx` < `aliveIdent`.len, "Cannot delete, instance is out of range"
          if `aliveIdent`[`delIdx`]:
            `userFinalCode`
            # Only add something to the delete list if its still alive, duplicate items would means all kinds of chaos.
            `aliveIdent`[`delIdx`] = false
            # Let delete know this index is now free.

            # TODO: With many items being deleted rapidly, the seq behind this will suffer much memory allocation and data moving.
            `handleDelStorageItem`
            # Clear the memory for this type.
            `clearOnDelete`
        ## Create a new component instance. Does not update systems.
        template newInstance*(`tyParam`: typedesc[`typeNameIdent`] | typedesc[`instanceTypeIdent`]): `instanceTypeIdent` =
          let res = `createIdent`()
          `userInitCode`
          res
        ## Create a new component instance from the supplied value. Does not update systems.
        proc newInstance*(`valueParam`: `typeNameIdent`): `instanceTypeIdent` {.inline.} =
          `res` = `rawCreate`
          `newCompUpdate`
          `userInitCode`
        ## Creates a new component from a generated `ref` component descendant. Does not update systems.
        template newInstance*(`tyParam`: typedesc[`typeNameIdent`] | typedesc[`instanceTypeIdent`], val: Component): untyped =
          newInstance(`refTypeNameIdent`(val).value)
        ## Marks a component as deleted. Does not update systems.
        template delInstance*(`tyParam`: `typeNameIdent` | `instanceTypeIdent`): untyped = `tyParam`.`deleteIdent`()

        ## Updating storage.
        ## `update` operates as a simple assignment into the storage array and therefore operates on the type's `==` proc.
        template update*(`instParam`: `instanceTypeIdent`, `valueParam`: `typeNameIdent`): untyped =
          `standAloneUpdate`

        template componentCount*(`tyParam`: typedesc[`typeNameIdent`] | typedesc[`instanceTypeIdent`]): untyped =
          ## Returns an estimate of the number of allocated components.
          ## This value is based on last index used and the number of indexes waiting to be used (from previous deletes).
          # Value zero is invalid, so we subtract the index by one.
          let freeCount = `freeIdxIdent`.len
          `componentLen` - freeCount
      )

    typeAccess.add(quote do:
      template `eqOp`*(i1, i2: `instanceTypeIdent`): bool = i1.int == i2.int

      template toRef*(inst: `instTypeNode`): ComponentRef =
        ## Utility function that takes this type's distinct `ComponentIndex`,
        ## returned for example from fetchComponent, and creates a reference
        ## tuple for the live component currently at this index.
        let i = inst  # Prevents duplicate instantiation of `inst`.
        (i.typeId, i.ComponentIndex, i.generation)
      )

  result.add typeAccess
  result.add firstCompIdInits

  # Add a generated type classes that cover all the types we've registered here.
  var
    compTypeNodes: seq[NimNode]
    refTypeNodes: seq[NimNode]
    instanceTypeNode: seq[NimNode]
  
  for typeId in id.unsealedComponents:
    compTypeNodes.add ident id.typeName(typeId)
    refTypeNodes.add ident id.refType(typeId)
    instanceTypeNode.add ident id.instanceType(typeId)
  
  result.add genTypeClass(typeClassName(), true, compTypeNodes)
  result.add genTypeClass(refTypeClassName(), true, refTypeNodes)
  result.add genTypeClass(instanceTypeClassName(), true, instanceTypeNode)

  # Add an `add` for `ComponentList` that handles `typeId`.
  let
    allCompsTC = ident typeClassName()
    allInstTC = ident instanceTypeClassName()
    allRefCompsTc = ident refTypeClassName()
  
  result.add(quote do:
    proc add*(items: var ComponentList, component: `allCompsTC`|`allInstTC`|`allRefCompsTc`) =
      ## Add a component to a component list, automatically handling `typeId`.
      when component is `allRefCompsTc`:
        const cRange = `identity`.typeIdRange()
        if component.typeId.int notin cRange.a.int .. cRange.b.int:
          # Attempt to determine the typeId.
          var copy = component
          copy.fTypeId = component.typeId()
          system.add items, copy
        else:
          system.add items, component
      else:
        system.add items, component.makeContainer()
      assert items[^1].typeId != InvalidComponent,
        "Could not resolve type id for " & $component.type
    )

macro cl*(items: varargs[untyped]): untyped =
  ## Create a component list from the parameters.
  ## 
  ## Parameters may be mixed between the source component types and
  ## ref template types.
  ## 
  ## Requires components to be registered.
  result = newStmtList()
  let
    res = genSym(nskVar, "cl")
    length = newLit items.len
  result.add(quote do:
    var `res` = newSeqOfCap[Component](`length`)
  )

  for item in items:
    result.add(quote do:
      add(`res`, `item`)
      
      assert `res`[^1].typeId.int != InvalidComponent.int,
        "Add type id failed"
    )
  result.add(res)

macro registerComponents*(id: static[EcsIdentity], options: static[ECSCompOptions], body: untyped): untyped =
  ## Registers the root type declarations in `body` as components for use in an ECS.
  ## 
  ## Adds the components to the identity specified by `id`.
  ## 
  ## .. code-block:: nim
  ##   registerComponents(myOptions):
  ##     type
  ##       Component1* = object
  ##         value: int
  ##       Component2* = object
  ## 
  ## For each type the following is generated:
  ## 
  ##   - A ref container type descended from `Component` with a
  ##     `typeId: ComponentTypeId` field.
  ## 
  ##   - A static `typeId` template to associate the type and its
  ##     container type with a unique `ComponentTypeId`.
  ## 
  ##   - An `instance` type that provides direct access to a particular component instance
  ##     attached to an entity.
  ## 
  ##   - An initialiser macro for creating ref containers with the
  ##     `typeId` set for you.
  ## 
  ## The contents of `body` is appended to the result after the
  ## above has been defined, allowing components that reference instances:
  ## 
  ## .. code-block:: nim
  ##   registerComponents(myOptions):
  ##     type
  ##       Comp1* = object
  ##         comp2: Comp2Instance
  ##       Comp2* = object
  ##         comp1: Comp1Instance
  id.doRegisterComponents(options, body)

macro registerComponentsFromFile*(id: EcsIdentity, compOpts: ECSCompOptions, filename: static[string]): untyped =
  ## The file referenced in `filename` is passed to
  ## `registerComponents` as the `body` parameter. This should
  ## include one or more type definitions to use as components.
  let types = staticRead(filename).parseStmt
  quote do:
    registerComponents(`id`, `compOpts`, `types`)

template registerComponents*(compOpts: ECSCompOptions, body: untyped): untyped =
  ## Registers the root type declarations in `body` as components for use in an ECS.
  ## 
  ## Adds the components to `defaultIdentity`.
  ## 
  ## .. code-block:: nim
  ##   registerComponents(myOptions):
  ##     type
  ##       Component1* = object
  ##         value: int
  ##       Component2* = object
  ## 
  ## For each type the following is generated:
  ## 
  ##   - A ref container type descended from `Component` with a
  ##     `typeId: ComponentTypeId` field.
  ## 
  ##   - A static `typeId` template to associate the type and its
  ##     container type with a unique `ComponentTypeId`.
  ## 
  ##   - An `instance` type that provides direct access to a particular component instance
  ##     attached to an entity.
  ## 
  ##   - An initialiser macro for creating ref containers with the
  ##     `typeId` set for you.
  ## 
  ## The contents of `body` is appended to the result after the
  ## above has been defined, allowing components that reference instances:
  ## 
  ## .. code-block:: nim
  ##   registerComponents(myOptions):
  ##     type
  ##       Comp1* = object
  ##         comp2: Comp2Instance
  ##       Comp2* = object
  ##         comp1: Comp1Instance
 
  defaultIdentity.registerComponents(compOpts, body)

proc genForAllComponents(id: EcsIdentity, typeId: ComponentTypeId, actions: NimNode): NimNode =
  let
    n = id.typeName typeId
    instType = newIdentNode instanceTypeName(n)
    accessArray = newIdentNode storageFieldName(n)
  result = newStmtList(quote do:
    template componentTypeId: untyped = `typeId`
    template componentName: untyped = `n`
    template componentInstType: untyped = `instType`
    for i in 0 ..< `accessArray`.len:
      template index: untyped = i
      template component: untyped = `accessArray`[i]
      `actions`
  )

macro forAllComponents*(id: static[EcsIdentity], typeId: static[ComponentTypeId], actions: untyped): untyped =
  ## Perform `actions` for every component of run time type `typeId`.
  id.genForAllComponents(typeId, actions)

template forAllComponents*(id: static[EcsIdentity], typeVal: typedesc, actions: untyped): untyped =
  id.forAllComponents(typeVal.typeId, actions)

macro forAllComponentTypes*(id: static[EcsIdentity], actions: untyped): untyped =
  ## Perform `actions` for every component type currently defined,
  ## not including InvalidComponent.
  result = newStmtList()
  for typeId in id.allComponentsSeq:
    result.add id.genForAllComponents(typeId, actions)

macro clearAll*(): untyped =
  result = quote do:
    forAllComponentTypes:
      forAllComponents:
        typeId.clear

proc toInt*(c: ComponentTypeId): int = c.int

macro componentsDefined*(id: static[EcsIdentity]): untyped =
  ## Returns the count of components defined so far in the compile process.
  newLit id.components.len
