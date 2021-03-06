/*
 * Copyright (c) 2002-2017 "Neo Technology,"
 * Network Engine for Objects in Lund AB [http://neotechnology.com]
 *
 * This file is part of Neo4j.
 *
 * Neo4j is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import Rx from 'rxjs/Rx'
import bolt from 'services/bolt/bolt'
import { hydrate } from 'services/duckUtils'
import { getJmxValues, getServerConfig } from 'services/bolt/boltHelpers'
import {
  CONNECTED_STATE,
  CONNECTION_SUCCESS,
  connectionLossFilter,
  DISCONNECTION_SUCCESS,
  LOST_CONNECTION,
  UPDATE_CONNECTION_STATE
} from 'shared/modules/connections/connectionsDuck'

export const NAME = 'meta'
export const UPDATE_META = 'meta/UPDATE_META'
export const UPDATE_SERVER = 'meta/UPDATE_SERVER'
export const UPDATE_SETTINGS = 'meta/UPDATE_SETTINGS'
export const CLEAR = 'meta/CLEAR'
export const FORCE_FETCH = 'meta/FORCE_FETCH'

const initialState = {
  labels: [],
  relationshipTypes: [],
  properties: [],
  functions: [],
  procedures: [],
  server: {
    version: null,
    edition: null,
    storeId: null
  },
  settings: {
    'browser.allow_outgoing_connections': false
  }
}

/**
 * Selectors
 */
export function getMetaInContext (state, context) {
  const inCurrentContext = (e) => e.context === context

  const labels = state.labels.filter(inCurrentContext)
  const relationshipTypes = state.relationshipTypes.filter(inCurrentContext)
  const properties = state.properties.filter(inCurrentContext)
  const functions = state.functions.filter(inCurrentContext)
  const procedures = state.procedures.filter(inCurrentContext)

  return {
    labels,
    relationshipTypes,
    properties,
    functions,
    procedures
  }
}

export const getVersion = (state) => state[NAME].server.version
export const getEdition = (state) => state[NAME].server.edition
export const isEnterprise = (state) => state[NAME].server.edition === 'enterprise'
export const getStoreId = (state) => state[NAME].server.storeId

export const getAvailableSettings = (state) => (state[NAME] || initialState).settings
export const allowOutgoingConnections = (state) => getAvailableSettings(state)['browser.allow_outgoing_connections']

/**
 * Helpers
 */
function updateMetaForContext (state, meta, context) {
  const notInCurrentContext = (e) => e.context !== context
  const mapResult = (metaIndex, mapFunction) => meta.records[metaIndex].get(1).map(mapFunction)
  const mapSingleValue = (r) => ({ val: r, context })
  const mapInvokableValue = (r) => {
    const { name, signature, description } = r
    return {
      val: name, context, signature, description
    }
  }

  const labels = state
    .labels
    .filter(notInCurrentContext)
    .concat(mapResult(0, mapSingleValue))
  const relationshipTypes = state
    .relationshipTypes
    .filter(notInCurrentContext)
    .concat(mapResult(1, mapSingleValue))
  const properties = state
    .properties
    .filter(notInCurrentContext)
    .concat(mapResult(2, mapSingleValue))
  const functions = state
    .functions
    .filter(notInCurrentContext)
    .concat(mapResult(3, mapInvokableValue))
  const procedures = state
    .procedures
    .filter(notInCurrentContext)
    .concat(mapResult(4, mapInvokableValue))

  return {
    labels,
    relationshipTypes,
    properties,
    functions,
    procedures
  }
}

/**
 * Reducer
 */
export default function meta (state = initialState, action) {
  state = hydrate(initialState, state)

  switch (action.type) {
    case UPDATE_META:
      return {...state, ...updateMetaForContext(state, action.meta, action.context)}
    case UPDATE_SERVER:
      return {...state, server: { version: action.version, edition: action.edition, storeId: action.storeId }}
    case UPDATE_SETTINGS:
      return {...state, settings: { ...action.settings }}
    case CLEAR:
      return { ...initialState }
    default:
      return state
  }
}

// Actions
export function updateMeta (meta, context) {
  return {
    type: UPDATE_META,
    meta,
    context
  }
}
export function fetchMetaData () {
  return {
    type: FORCE_FETCH
  }
}

export const updateSettings = (settings) => {
  return {
    type: UPDATE_SETTINGS,
    settings
  }
}

// Epics
export const metaQuery = `
CALL db.labels() YIELD label
WITH COLLECT(label) AS labels
RETURN 'labels' as a, labels as result
UNION
CALL db.relationshipTypes() YIELD relationshipType
WITH COLLECT(relationshipType) AS relationshipTypes
RETURN 'relationshipTypes' as a, relationshipTypes as result
UNION
CALL db.propertyKeys() YIELD propertyKey
WITH COLLECT(propertyKey) AS propertyKeys
RETURN 'propertyKeys' as a, propertyKeys as result
UNION
CALL dbms.functions() YIELD name, signature, description
WITH collect({name: name, signature: signature, description: description}) as functions
RETURN 'functions' as a, functions AS result
UNION
CALL dbms.procedures() YIELD name, signature, description
WITH collect({name: name, signature: signature, description: description}) as procedures
RETURN 'procedures' as a, procedures as result
`

export const dbMetaEpic = (some$, store) =>
  some$.ofType(UPDATE_CONNECTION_STATE).filter((s) => s.state === CONNECTED_STATE)
    .merge(some$.ofType(CONNECTION_SUCCESS))
    .mergeMap(() => {
      return Rx.Observable.timer(0, 20000)
        .merge(some$.ofType(FORCE_FETCH))
        // Labels, types and propertyKeys
        .mergeMap(() =>
          Rx.Observable
            .fromPromise(bolt.routedReadTransaction(metaQuery))
            .catch((e) => Rx.Observable.of(null))
        )
        .filter((r) => r)
        .do((res) => store.dispatch(updateMeta(res)))
        // Version and edition
        .mergeMap(() => {
          return Rx.Observable
            .fromPromise(getJmxValues([
              ['Kernel', 'KernelVersion'],
              ['Kernel', 'StoreId'],
              ['Configuration', 'unsupported.dbms.edition']
            ]))
            .catch((e) => Rx.Observable.of(null))
        })
        .do((res) => {
          if (!res) return
          const [ kvObj, storeObj, edObj ] = res
          const versionMatch = kvObj.KernelVersion.match(/version:\s([^,]+),/)
          const version = versionMatch[1]
          const edition = edObj['unsupported.dbms.edition']
          const storeId = storeObj['StoreId']
          store.dispatch({
            type: UPDATE_SERVER,
            version,
            edition,
            storeId
          })
        })
        // Server config for browser
        .mergeMap(() => {
          return getServerConfig(['browser.'])
            .then((settings) => {
              if (settings) store.dispatch(updateSettings(settings))
              return null
            })
        })
        .takeUntil(some$.ofType(LOST_CONNECTION).filter(connectionLossFilter))
        .mapTo({ type: 'NOOP' })
    })

export const clearMetaOnDisconnectEpic = (some$, store) =>
  some$.ofType(DISCONNECTION_SUCCESS)
    .mapTo({ type: CLEAR })
