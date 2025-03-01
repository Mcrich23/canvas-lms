/*
 * Copyright (C) 2023 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

// @ts-ignore
import React, {useEffect, useState} from 'react'
// @ts-ignore
import doFetchApi from '@canvas/do-fetch-api-effect'
import {EnrollmentTreeGroup} from './EnrollmentTreeGroup'
import {Spinner} from '@instructure/ui-spinner'

interface RoleChoice {
  id: string
  baseRoleName: string
}

interface Props {
  list: {}[]
  roles: {id: string; label: string; base_role_name: string}[]
  selectedRole: RoleChoice
  createEnroll?: Function
}

export interface NodeStructure {
  children: NodeStructure[]
  enrollId?: string
  id: string
  isCheck: boolean
  isMismatch?: boolean
  isMixed: boolean
  isToggle?: boolean
  label: string
  parent?: NodeStructure
  workState?: string
}

interface Section {
  course_section_id: string
  course_id: string
  id: string
}

export function EnrollmentTree(props: Props) {
  const [tree, setTree] = useState<NodeStructure[]>([])
  const [loading, setLoading] = useState(true)

  function splitArrayByProperty(arr: any[], property: string | number) {
    return arr.reduce((result: {[x: string]: any[]}, obj: {[x: string]: any}) => {
      const index = obj[property]
      if (!result[index]) {
        result[index] = []
      }
      result[index].push(obj)
      return result
    }, {})
  }

  const sortByBase = (a: NodeStructure, b: NodeStructure) => {
    const aId = a.id.slice(1)
    const bId = b.id.slice(1)

    const aBase = props.roles[props.roles.findIndex(r => r.id === aId)].base_role_name
    const bBase = props.roles[props.roles.findIndex(r => r.id === bId)].base_role_name

    switch (aBase) {
      case 'TeacherEnrollment':
        return -1
      case 'TaEnrollment':
        if (bBase === 'TeacherEnrollment') {
          return 1
        } else {
          return -1
        }
      case 'DesignerEnrollment':
        if (bBase === 'StudentEnrollment') {
          return -1
        } else {
          return 1
        }
      case 'StudentEnrollment':
        return 1
      default:
        return 0
    }
  }

  useEffect(() => {
    if (props.createEnroll) {
      props.createEnroll(tree)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.createEnroll])

  useEffect(() => {
    if (!loading) {
      if (props.selectedRole.baseRoleName !== '') {
        for (const roles in tree) {
          if (tree[roles].label.toLowerCase() === props.selectedRole.baseRoleName.toLowerCase()) {
            tree[roles].isToggle = true
            // set mismatch for all sections and courses with role
            for (const course of tree[roles].children) {
              course.isMismatch = false
              for (const section of course.children) {
                section.isMismatch = false
              }
            }
          } else {
            for (const course of tree[roles].children) {
              course.isMismatch = course.isCheck
              for (const section of course.children) {
                section.isMismatch = section.isCheck
              }
            }
          }
        }
      }
    }
    setTree([...tree])
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.selectedRole.baseRoleName, loading])

  // builds basic object tree
  useEffect(() => {
    // populate a data structure with the information needed for each row
    const enrollByRole = splitArrayByProperty(props.list, 'role_id')
    const coursePromises = []
    // ids are shared between role/course/section, so we need a prefix to distinguish type
    for (const role in enrollByRole) {
      const roleData = props.roles.find((r: any) => {
        return r.id === role
      })
      if (roleData === undefined) {
        return
      }
      const rId = 'r' + role
      let roleCheck = false
      if (roleData.base_role_name === 'TeacherEnrollment') {
        roleCheck = true
      }
      const rNode = {
        id: rId,
        label: roleData?.label,
        // eslint-disable-next-line no-array-constructor
        children: new Array<NodeStructure>(),
        isToggle: false,
        isMixed: false,
        isCheck: roleCheck,
      }
      tree.push(rNode)

      const enrollByCourse = splitArrayByProperty(enrollByRole[role], 'course_id')
      coursePromises.push(getRoles(enrollByCourse, rNode))
    }
    Promise.all(coursePromises)
      .then(() => {
        tree.sort(sortByBase)
        setTree([...tree])
        setLoading(false)
      })
      .catch(() => {})
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const getRoles = (role: any[], rNode: NodeStructure) => {
    const coursePromises = []

    for (const [, value] of Object.entries(role)) {
      const coursePromise = getCourses(value, rNode).catch(error => {
        // eslint-disable-next-line no-console
        console.error('Error fetching courses for role:', value, error)

        // preserve the role structure and coursePromises continuity by returning null
        return null
      })

      coursePromises.push(coursePromise)
    }

    return Promise.all(coursePromises)
  }

  const getCourses = async (course: any[], rNode: NodeStructure) => {
    const courseId = course[0].course_id
    const cId = 'c' + courseId
    const childArray: NodeStructure[] = []

    let cJson
    try {
      cJson = await doFetchApi({path: `/api/v1/courses/${courseId}`})
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error('Error fetching course data for ID:', courseId, error)

      // re-throw the error to be caught by the calling function
      throw error
    }

    const cNode = {
      isMismatch: false,
      id: cId,
      label: cJson.json.name,
      parent: rNode,
      isCheck: rNode.isCheck,
      children: childArray,
      isToggle: false,
      workState: cJson.json.workflow_state,
      isMixed: false,
    }

    const secPromises = [cJson]
    rNode.children.push(cNode)

    for (const section of course) {
      const sectionPromise = getSectionDetails(section, cNode).catch(error => {
        // eslint-disable-next-line no-console
        console.error('Error fetching section data for section:', section, error)
      })

      secPromises.push(sectionPromise)
    }

    return Promise.all(secPromises)
  }

  const getSectionDetails = async (
    section: Section,
    courseNode: NodeStructure
  ): Promise<any | null> => {
    try {
      const sectionJson = await doFetchApi({
        path: `/api/v1/courses/${section.course_id}/sections/${section.course_section_id}`,
      })

      const sectionNode = {
        isMismatch: false,
        id: `s${section.course_section_id}`,
        label: sectionJson.json.name,
        parent: courseNode,
        isCheck: courseNode.isCheck,
        children: [],
        enrollId: section.id,
        isMixed: false,
      }

      courseNode.children.push(sectionNode)

      return sectionJson
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error(
        `Error fetching section details for course_section_id: ${section.course_section_id} and course_id: ${section.course_id}`,
        error
      )

      // returning null as fallback
      return null
    }
  }

  const locateNode = (node: NodeStructure) => {
    let currNode = node
    const nodePath: string[] = [currNode.id]
    while (currNode.parent) {
      nodePath.push(currNode.parent.id)
      currNode = currNode.parent
    }
    const rId = nodePath[nodePath.length - 1]

    let nextIndex = tree.findIndex(n => n.id === nodePath[nodePath.length - 1])
    let nextNode = tree[nextIndex]
    for (let i = nodePath.length - 2; i >= 0; i--) {
      nextIndex = nextNode.children.findIndex(n => n.id === nodePath[i])
      nextNode = nextNode.children[nextIndex]
    }
    currNode = nextNode
    return {currNode, rId}
  }

  const updateTreeCheck = (node: NodeStructure, newState: boolean) => {
    // change all children to match status of parent
    const {currNode, rId} = locateNode(node)
    const isRole = rId.slice(1) === props.selectedRole.id || props.selectedRole.id === ''
    if (currNode.children) {
      for (const c of currNode.children) {
        c.isMismatch = isRole ? false : newState
        c.isCheck = newState
        if (c.children) {
          for (const s of c.children) {
            s.isMismatch = isRole ? false : newState
            s.isCheck = newState
          }
        }
      }
    }
    currNode.isCheck = newState
    currNode.isMixed = false
    currNode.isMismatch = newState
    if (isRole) {
      currNode.isMismatch = false
    }
    // set parents to mixed based on sibling state
    setParents(currNode, newState, isRole)
    setTree([...tree])
  }

  const setParents = (currNode: NodeStructure, newState: boolean, isRole: boolean) => {
    let sibMixed = false
    if (currNode.parent) {
      const parent = currNode.parent
      for (const siblings of parent.children) {
        if (siblings.isCheck !== newState) {
          sibMixed = true
        }
      }
      parent.isCheck = sibMixed ? false : newState
      parent.isMixed = sibMixed
      parent.isMismatch = sibMixed || newState
      // again for role parents
      if (isRole) {
        parent.isMismatch = false
      }
      if (parent.parent) {
        const roleParent = parent.parent
        let auntMixed = false
        for (const siblings of roleParent.children) {
          if (siblings.isCheck !== newState || siblings.isMixed) {
            auntMixed = true
          }
        }
        roleParent.isCheck = auntMixed ? false : newState
        roleParent.isMixed = auntMixed
      }
    } else {
      currNode.isMixed = false
    }
  }

  const updateTreeToggle = (node: NodeStructure, newState: boolean) => {
    const {currNode} = locateNode(node)
    currNode.isToggle = newState
    setTree([...tree])
  }

  const renderTree = () => {
    const roleElements = []
    for (const role in tree) {
      roleElements.push(
        <EnrollmentTreeGroup
          key={tree[role].id}
          id={tree[role].id}
          label={tree[role].label}
          indent="0"
          updateCheck={(node: NodeStructure, state: boolean) => {
            updateTreeCheck(node, state)
          }}
          updateToggle={(node: NodeStructure, state: boolean) => {
            updateTreeToggle(node, state)
          }}
          isCheck={tree[role].isCheck}
          isToggle={tree[role].isToggle}
          isMixed={tree[role].isMixed}
        >
          {[...tree[role].children]}
        </EnrollmentTreeGroup>
      )
    }
    return <>{roleElements}</>
  }

  if (loading) {
    return <Spinner size="medium" renderTitle="Loading enrollments" margin="auto" />
  } else {
    return renderTree()
  }
}
