###!
Copyright (c) 2002-2016 "Neo Technology,"
Network Engine for Objects in Lund AB [http://neotechnology.com]

This file is part of Neo4j.

Neo4j is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
###

'use strict';

angular.module('neo4jApp.services')
  .factory 'Bolt', [
    'Settings'
    'AuthDataService'
    'localStorageService'
    '$rootScope'
    '$location'
    '$q'
    (Settings, AuthDataService, localStorageService, $rootScope, $location, $q) ->
      bolt = window.neo4j.v1
      _driver = null

      getDriverObj = (withoutCredentials = no) ->
        authData = AuthDataService.getPlainAuthData()
        host = Settings.boltHost || $location.host()
        encrypted = if $location.protocol() is 'https' then yes else no
        [_m, username, password] = if authData then authData.match(/^([^:]+):(.*)$/) else ['','','']
        if withoutCredentials
          driver = bolt.driver("bolt://" + host, {}, {encrypted: encrypted})
        else
          driver = bolt.driver("bolt://" + host, bolt.auth.basic(username, password), {encrypted: encrypted})
        driver

      testQuery = (driver) ->
        q = $q.defer()
        driver.onError = (e) -> 
          if e instanceof Event and e.type is 'error'
            q.reject getSocketErrorObj()
          else if e.code and e.message # until Neo4jError is in drivers public API
            q.reject buildErrorObj(e.code, e.message)
        session = driver.session()
        p = session.run("CALL db.labels")
        p.then((r) ->
          session.close()
          q.resolve r
        ).catch((e)->
          session.close()
          q.reject e
        )
        q.promise

      testConnection = (withoutCredentials = no) ->
        q = $q.defer()
        driver = getDriverObj withoutCredentials
        testQuery(driver).then((r) -> 
          q.resolve r
          driver.close()
        ).catch((e) -> 
          q.reject e
          driver.close()
        )
        q.promise

      connect = (withoutCredentials = no) ->
        q = $q.defer()
        _driver = getDriverObj withoutCredentials
        testQuery(_driver)
          .then((r) -> q.resolve r)
          .catch((e) -> 
            _driver = null
            q.reject e
          )
        q.promise

      createSession = () ->
        return _driver.session() if _driver
        return no

      beginTransaction = (opts) ->
        q = $q.defer()
        statement = opts[0]?.statement || ''
        session = createSession()
        if not session
          tx = null
          q.reject getSocketErrorObj()
        else
          tx = session.beginTransaction()
          q.resolve() unless statement
          tx.run(statement).then((r)-> q.resolve(r)).catch((e)-> q.reject(e)) if statement
        return {tx: tx, session: session, promise: q.promise}

      transaction = (opts, session, tx) ->
        statement = opts[0]?.statement || ''
        q = $q.defer()
        session = session || createSession()
        if not session
          q.reject getSocketErrorObj()
        else
          if tx
            p = tx.run statement
            tx.commit()
          else
            p = session.run statement
          p.then((r) ->
            session.close()
            q.resolve r
          ).catch((e) ->
            session.close()
            q.reject e
          )
        {tx: tx, promise: q.promise}

      callProc = (query) ->
        statements = if query then [{statement: "CALL " + query}] else []
        result = transaction(statements)
        q = $q.defer()
        result.promise.then((res) ->
          q.resolve(res.records)
        ).catch((err) ->
          q.resolve([])
        )
        q.promise

      metaResultToRESTResult = (labels, realtionshipTypes, propertyKeys) ->
        labels: labels.map (o) -> o.get('label')
        relationships: realtionshipTypes.map (o) -> o.get('relationshipType')
        propertyKeys: propertyKeys.map (o) -> o.get('propertyKey')

      schemaResultToRESTResult = (indexes, constraints) ->
        indexString = ""
        constraintsString = ""
        if (indexes.length == 0)
          indexString =  "No indexes"
        else
          indexString = "Indexes"
          for index in indexes
            indexString += "\n  #{index.get('description').replace('INDEX','')} #{index.get('state').toUpperCase()}"
            if index.get("type") == "node_unique_property"
              indexString += " (for uniqueness constraint)"
        if (constraints.length == 0)
          constraintsString = "No constraints"
        else
          constraintsString = "Constraints"
          for constraint in constraints
            constraintsString += "\n  #{constraint.get('description').replace('CONSTRAINT','')}"
        return "#{indexString}\n\n#{constraintsString}\n"

      boltResultToRESTResult = (result) ->
        res = result.records || []
        obj = {
          config: {},
          headers: -> [],
          data: {
            results: [{
              columns: [],
              data: [],
              stats: {},
              }],
            notifications: (if result.summary && result.summary.notifications then result.summary.notifications else []),
            errors: []
          }
        }
        if result.fields
          obj.data.errors = result.fields
          return obj
        if result.code and result.message  # until Neo4jError is in drivers public API
          return boltResultToRESTResult(buildErrorObj(result.code, result.message))
        keys = if res.length then res[0].keys else []
        obj.data.results[0].columns = keys
        obj.data.results[0].plan = boltPlanToRESTPlan result.summary.plan if result.summary and result.summary.plan
        obj.data.results[0].plan = boltPlanToRESTPlan result.summary.profile if result.summary and result.summary.profile
        obj.data.results[0].stats = boltStatsToRESTStats result.summary
        res = itemIntToString res
        rows = res.map((record) ->
          return {
            row: getRESTRowsFromBolt record, keys
            meta: getRESTMetaFromBolt record, keys
            graph: getRESTGraphFromBolt record, keys
          }
        )
        obj.data.results[0]['data'] = rows
        return obj

      getRESTRowsFromBolt = (record, keys) ->
        keys.reduce((tot, curr) ->
          res = extractDataForRowsFormat(record.get(curr))
          res = [res] if Array.isArray res
          tot.concat res
        , [])

      getRESTMetaFromBolt = (record, keys) ->
        items = keys.map((key) -> record.get(key))
        items.map((item) ->
          type = 'node' if item instanceof bolt.types.Node
          type = 'relationship' if item instanceof bolt.types.Relationship
          return {id: item.identity, type: type} if type
          null
        )

      getRESTGraphFromBolt = (record, keys) ->
        items = keys.map((key) -> record.get(key))
        graphItems = [].concat.apply([],  extractDataForGraphFormat(items))
        graphItems.map((item) ->
          item.id = item.identity
          delete item.identity
          return item
        )
        nodes = graphItems.filter((item) -> item instanceof bolt.types.Node)
        rels = graphItems.filter((item) -> item instanceof bolt.types.Relationship)
          .map((item) ->
            item.startNode = item.start
            item.endNode = item.end
            delete item.start
            delete item.end
            return item
          )
        {nodes: nodes, relationships: rels}

      extractDataForRowsFormat = (item) ->
        return item.properties if item instanceof bolt.types.Node
        return item.properties if item instanceof bolt.types.Relationship
        return [].concat.apply([], extractPathForRowsFormat(item)) if item instanceof bolt.types.Path
        return item if item is null
        return item.map((subitem) -> extractDataForRowsFormat subitem) if Array.isArray item
        if typeof item is 'object'
          out = {}
          Object.keys(item).forEach((key) => out[key] = extractDataForRowsFormat(item[key]))
          return out
        item

      extractPathForRowsFormat = (path) ->
        path.segments.map((segment) -> [
          extractDataForRowsFormat(segment.start),
          extractDataForRowsFormat(segment.relationship),
          extractDataForRowsFormat(segment.end)
        ])

      extractPathsForGraphFormat = (paths) ->
        paths = [paths] unless Array.isArray paths
        paths.reduce((all, path) ->
          path.segments.forEach((segment) ->
            all.push(segment.start)
            all.push(segment.end)
            all.push(segment.relationship)
          )
          return all
        , [])

      extractDataForGraphFormat = (item) ->
        return item if item instanceof bolt.types.Node
        return item if item instanceof bolt.types.Relationship
        return [].concat.apply([], extractPathsForGraphFormat(item)) if item instanceof bolt.types.Path
        return no if item is null
        return item.map((subitem) -> extractDataForGraphFormat subitem).filter((i) -> i) if Array.isArray item
        if typeof item is 'object'
          out = Object.keys(item).map((key) -> extractDataForGraphFormat(item[key])).filter((i) -> i)
          return no if not out.length
          return out
        no

      itemIntToString = (item) ->
        return arrayIntToString item if Array.isArray(item)
        return item if typeof item in ['number', 'string']
        return item if item is null
        return item.toString() if bolt.isInt item
        return objIntToString item if typeof item is 'object'

      arrayIntToString = (arr) ->
       arr.map((item) -> itemIntToString item)

      objIntToString = (obj) ->
        Object.keys(obj).forEach((key) ->
          obj[key] = itemIntToString obj[key]
        )
        obj

      boltPlanToRESTPlan = (plan) ->
        obj = boltPlanToRESTPlanShared plan
        obj['runtime-impl'] = plan.arguments['runtime-impl']
        obj['planner-impl'] = plan.arguments['planner-impl']
        obj['version'] = plan.arguments['version']
        obj['KeyNames'] = plan.arguments['KeyNames']
        obj['planner'] = plan.arguments['planner']
        obj['runtime'] = plan.arguments['runtime']
        {root: obj}

      boltPlanToRESTPlanShared = (plan) ->
        return {
          operatorType: plan.operatorType,
          LegacyExpression: plan.arguments.LegacyExpression,
          ExpandExpression: plan.arguments.ExpandExpression,
          DbHits: plan.dbHits,
          Rows: plan.rows,
          EstimatedRows: plan.arguments.EstimatedRows,
          identifiers: plan.identifiers,
          children: plan.children.map boltPlanToRESTPlanShared
        }

      boltStatsToRESTStats = (summary) ->
        return {} unless summary and summary.updateStatistics
        stats = summary.updateStatistics._stats
        newStats = {}
        Object.keys(stats).forEach((key) ->
          newKey = key.replace(/([A-Z]+)/, (m) -> '_' + m.toLowerCase())
          newStats[newKey] = stats[key]
        )
        newStats['contains_updates'] = summary.updateStatistics.containsUpdates()
        newStats

      getSocketErrorObj = ->
        buildErrorObj 'Socket.Error', 'Socket error. Is the server online and have websockets open?'

      buildErrorObj = (code, message) ->
        return {
          fields: [{
            code: code,
            message: message
          }]
        }

      connect()
      $rootScope.$on 'LocalStorageModule.notification.setitem', (evt, item) =>
        connect() if item.key is 'authorization_data'
      $rootScope.$on 'LocalStorageModule.notification.removeitem', (evt, item) =>
        connect() if item.key is 'authorization_data'

      return {
        testConnection: testConnection,
        connect: connect,
        beginTransaction: beginTransaction,
        transaction: transaction,
        callProcedure: (procedureName) ->
          callProc(procedureName)
        constructResult: (res) ->
          boltResultToRESTResult res
        constructMetaResult: (labels, realtionshipTypes, propertyKeys) ->
          metaResultToRESTResult labels, realtionshipTypes, propertyKeys
        constructSchemaResult: (indexes, constraints) ->
          schemaResultToRESTResult indexes, constraints
      }
  ]