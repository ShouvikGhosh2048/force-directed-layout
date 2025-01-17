// This file is compiled as part of the `odin.dll` file. It contains the
// procs that `game_hot_reload.exe` will call, such as:
//
// game_init: Sets up the game state
// game_update: Run once per frame
// game_shutdown: Shuts down game and frees memory
// game_memory: Run just before a hot reload, so game.exe has a pointer to the
//		game's memory.
// game_hot_reloaded: Run after a hot reload so that the `g_mem` global variable
//		can be set to whatever pointer it was in the old DLL.
//
// Note: When compiled as part of the release executable this whole package is imported as a normal
// odin package instead of a DLL.

package game

import "core:math"
import "core:math/rand"
import "core:math/linalg"
import "core:fmt"
import "core:slice"
import "core:os"
import "core:strings"
import "core:encoding/json"
import rl "vendor:raylib"

PIXEL_WINDOW_HEIGHT :: 180

Mode :: enum {
	Move,
	Vertex,
	Edge,
}

Vertex :: struct {
	position: [2]f32,
	velocity: [2]f32,
	acceleration: [2]f32,
	text: cstring,
}

BarnesHutTreeNode :: struct {
    position: [2]f32,
    dimension: [2]f32,
    number_of_vertices: int,
	center_of_mass: [2]f32,
	has_children: bool,
    children: [4]int,
}

create_barnes_hut_tree :: proc(tree: ^[dynamic]BarnesHutTreeNode, box_position: [2]f32, box_dimension: [2]f32, positions: [][2]f32) -> int {
	node := BarnesHutTreeNode {
		position = box_position,
		dimension = box_dimension,
		number_of_vertices = len(positions),
		children = { -1, -1, -1, -1 }, // Set -1 to detect possible errors.
	}

	if node.number_of_vertices > 0 {
		for position in positions {
			node.center_of_mass += position
		}
		node.center_of_mass /= f32(node.number_of_vertices)
	}

	if node.number_of_vertices > 1 && max(box_dimension.x, box_dimension.y) > 1e-6 {
		node.has_children = true

		curr := 0
		for i in 0..<len(positions) {
			if positions[i].x <= box_position.x + box_dimension.x / 2 &&
				positions[i].y <= box_position.y + box_dimension.y / 2 {
				positions[i], positions[curr] = positions[curr], positions[i]
				curr += 1
			}
		}
		size1 := curr
		node.children[0] = create_barnes_hut_tree(tree, box_position, box_dimension / 2, positions[:size1])

		for i in size1..<len(positions) {
			if positions[i].x > box_position.x + box_dimension.x / 2 &&
				positions[i].y <= box_position.y + box_dimension.y / 2 {
				positions[i], positions[curr] = positions[curr], positions[i]
				curr += 1
			}
		}
		size2 := curr
		node.children[1] = create_barnes_hut_tree(tree, box_position + { box_dimension.x / 2, 0 }, box_dimension / 2, positions[size1:size2])

		for i in size2..<len(positions) {
			if positions[i].x <= box_position.x + box_dimension.x / 2 &&
				positions[i].y > box_position.y + box_dimension.y / 2 {
				positions[i], positions[curr] = positions[curr], positions[i]
				curr += 1
			}
		}
		size3 := curr
		node.children[2] = create_barnes_hut_tree(tree, box_position + { 0, box_dimension.y / 2 }, box_dimension / 2, positions[size2:size3])

		node.children[3] = create_barnes_hut_tree(tree, box_position + box_dimension / 2, box_dimension / 2, positions[size3:])
	}

	append(tree, node)
	return len(tree) - 1
}

inverse_distance_from_position :: proc(tree: []BarnesHutTreeNode, root: int, position: [2]f32) -> [2]f32 {
	if tree[root].number_of_vertices == 0 {
		return { 0, 0 }
	}

	distance_to_center := linalg.length(tree[root].center_of_mass - position)
	region_size := max(tree[root].dimension.x, tree[root].dimension.y)
	// Threshold = 0.5 - https://beltoforion.de/en/barnes-hut-galaxy-simulator/
	// https://anaroxanapop.github.io/behalf
	if !tree[root].has_children || region_size / distance_to_center < 0.5 {
		return f32(tree[root].number_of_vertices) * linalg.normalize0(tree[root].center_of_mass - position) / max(1e-6, distance_to_center)
	} else {
		res: [2]f32
		for child_index in tree[root].children {
			res += inverse_distance_from_position(tree, child_index, position)
		}
		return res
	}
}

Game_Memory :: struct {
	camera_target: rl.Vector2,
	camera_zoom: f32,
	font: rl.Font,
	mode: Mode,
	vertices: [dynamic]Vertex,
	edges: [dynamic][2]int,
	dragging: bool,
	drag_start: [2]f32,
	drag_vertex_index: int,
	drag_left: bool,
	selected_vertices: [dynamic]int,
	selected_edges: [dynamic]int,
	apply_force: bool,
	quadtree: [dynamic]BarnesHutTreeNode,
	quadtree_positions: [dynamic][2]f32,
}

GraphFile :: struct {
	vertices: [dynamic]string,
	edges: [dynamic][2]int,
}

g_mem: ^Game_Memory

game_camera :: proc() -> rl.Camera2D {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())

	return {
		zoom = g_mem.camera_zoom,
		target = g_mem.camera_target,
		offset = { w/2, h/2 },
	}
}

@(export)
game_update :: proc() -> bool {
	SIDEBAR_WIDTH :: 200

	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	mouse_position := rl.GetMousePosition()
	mouse_world_position := rl.GetScreenToWorld2D(mouse_position, game_camera())
	mouse_x_within_canvas := SIDEBAR_WIDTH < mouse_position.x && mouse_position.x < w - SIDEBAR_WIDTH
	vertex_under_mouse := -1
	for vertex in g_mem.selected_vertices { // TODO: Do we care about order here?
		if linalg.distance(g_mem.vertices[vertex].position, mouse_world_position) < 10 {
			vertex_under_mouse = vertex
			break
		}
	}
	if vertex_under_mouse == -1 {
		for i := len(g_mem.vertices) - 1; i > -1; i -= 1 {
			if linalg.distance(g_mem.vertices[i].position, mouse_world_position) < 10 {
				vertex_under_mouse = i
				break
			}
		}
	}

	// Graph interactions
	// Zoom
	wheel := rl.GetMouseWheelMove()
	if wheel != 0 && mouse_x_within_canvas {
		g_mem.camera_zoom *= math.pow(1.1, wheel)
		new_mouse_world_position := rl.GetScreenToWorld2D(mouse_position, game_camera())

		// We move the camera to make the mouse_world_position appear under the mouse.
		g_mem.camera_target += mouse_world_position - new_mouse_world_position
	}

	// Left mouse - create/move
	switch g_mem.mode {
		case .Move: {
			// raylib [core] example - 2d camera mouse zoom
			if rl.IsMouseButtonPressed(.LEFT) && mouse_x_within_canvas && !g_mem.dragging {
				g_mem.dragging = true
				g_mem.drag_start = mouse_world_position
				g_mem.drag_left = true
				g_mem.drag_vertex_index = vertex_under_mouse
				if (vertex_under_mouse == -1) {
					clear(&g_mem.selected_vertices)
					clear(&g_mem.selected_edges)
				} else {
					mouse_vertex_in_selected := false
					for vertex in g_mem.selected_vertices {
						if vertex == vertex_under_mouse {
							mouse_vertex_in_selected = true
							break
						}
					}
					if !mouse_vertex_in_selected {
						clear(&g_mem.selected_vertices)
						clear(&g_mem.selected_edges)
						append(&g_mem.selected_vertices, vertex_under_mouse)
						g_mem.vertices[vertex_under_mouse].velocity = {0.0, 0.0}
					}
				}
			}
			else if g_mem.dragging && g_mem.drag_left { // We use else if since we want to update only if we started dragging before.
				if g_mem.drag_vertex_index == -1 {
					g_mem.camera_target -= rl.GetMouseDelta() / g_mem.camera_zoom // TODO: This will change mouse_world_position. Is this an issue?
				} else {
					for vertex in g_mem.selected_vertices {
						g_mem.vertices[vertex].position += rl.GetMouseDelta() / g_mem.camera_zoom
					}
				}
			}
			if rl.IsMouseButtonReleased(.LEFT) && g_mem.dragging && g_mem.drag_left {
				g_mem.dragging = false
			}
		}
		case .Vertex: {
			if rl.IsMouseButtonPressed(.LEFT) && mouse_x_within_canvas && !g_mem.dragging {
				g_mem.dragging = true
				g_mem.drag_start = mouse_world_position
				g_mem.drag_left = true
				if (vertex_under_mouse == -1) {
					clear(&g_mem.selected_vertices)
					clear(&g_mem.selected_edges)
					append(&g_mem.vertices, Vertex{ position = mouse_world_position })
					append(&g_mem.selected_vertices, len(g_mem.vertices) - 1)
					g_mem.vertices[len(g_mem.vertices) - 1].velocity = {0.0, 0.0}
					g_mem.drag_vertex_index = len(g_mem.vertices) - 1
					vertex_under_mouse = len(g_mem.vertices) - 1
				} else {
					mouse_vertex_in_selected := false
					for vertex in g_mem.selected_vertices {
						if vertex == vertex_under_mouse {
							mouse_vertex_in_selected = true
							break
						}
					}
					if !mouse_vertex_in_selected {
						clear(&g_mem.selected_vertices)
						clear(&g_mem.selected_edges)
						append(&g_mem.selected_vertices, vertex_under_mouse)
						g_mem.vertices[vertex_under_mouse].velocity = {0.0, 0.0}
					}
					g_mem.drag_vertex_index = vertex_under_mouse
				}
			} else if g_mem.dragging && g_mem.drag_left {
				assert(g_mem.drag_vertex_index > -1)
				for vertex in g_mem.selected_vertices {
					g_mem.vertices[vertex].position += rl.GetMouseDelta() / g_mem.camera_zoom
				}
			}
			if rl.IsMouseButtonReleased(.LEFT) && g_mem.dragging && g_mem.drag_left {
				g_mem.dragging = false
			}
		}
		case .Edge: {
			if rl.IsMouseButtonPressed(.LEFT) && mouse_x_within_canvas && !g_mem.dragging {
				if vertex_under_mouse > -1 {
					clear(&g_mem.selected_vertices)
					clear(&g_mem.selected_edges)
					g_mem.dragging = true
					g_mem.drag_start = mouse_world_position
					g_mem.drag_vertex_index = vertex_under_mouse
					g_mem.drag_left = true
				} else {
					clear(&g_mem.selected_vertices)
					edge_under_mouse := -1
					for edge_index in g_mem.selected_edges { // TODO: Do we care about order here?
						edge := g_mem.edges[edge_index]
						edge_vector := g_mem.vertices[edge[1]].position - g_mem.vertices[edge[0]].position
						mouse_vector := mouse_world_position - g_mem.vertices[edge[0]].position
						t : f32 = 0
						if linalg.length2(edge_vector) > 1e-6 {
							t = clamp(linalg.dot(edge_vector, mouse_vector) / linalg.length2(edge_vector), 0, 1)
						}
						closest_point := g_mem.vertices[edge[0]].position + t * edge_vector
						if linalg.distance(closest_point, mouse_world_position) < 10 {
							edge_under_mouse = edge_index
							break
						}
					}
					if edge_under_mouse == -1 {
						for edge, i in g_mem.edges { // TODO: Do we care about order here?
							edge_vector := g_mem.vertices[edge[1]].position - g_mem.vertices[edge[0]].position
							mouse_vector := mouse_world_position - g_mem.vertices[edge[0]].position
							t : f32 = 0
							if linalg.length2(edge_vector) > 1e-6 {
								t = clamp(linalg.dot(edge_vector, mouse_vector) / linalg.length2(edge_vector), 0, 1)
							}
							closest_point := g_mem.vertices[edge[0]].position + t * edge_vector
							if linalg.distance(closest_point, mouse_world_position) < 10 {
								edge_under_mouse = i
								break
							}
						}
					}

					if (edge_under_mouse == -1) {
						clear(&g_mem.selected_edges)
					} else {
						mouse_edge_in_selected := false
						for edge in g_mem.selected_edges {
							if edge == edge_under_mouse {
								mouse_edge_in_selected = true
								break
							}
						}
						if !mouse_edge_in_selected {
							clear(&g_mem.selected_edges)
							append(&g_mem.selected_edges, edge_under_mouse)
						}
					}
				}
			}
			if rl.IsMouseButtonReleased(.LEFT) && g_mem.dragging && g_mem.drag_left {
				drag_end_vertex_index := vertex_under_mouse
				if drag_end_vertex_index > -1 && drag_end_vertex_index != g_mem.drag_vertex_index {
					// TODO: This is slow, maybe use a set?
					edge_exists := false
					for edge in g_mem.edges {
						if edge[0] == g_mem.drag_vertex_index && edge[1] == drag_end_vertex_index {
							edge_exists = true
						}
					}

					if !edge_exists {
						append(&g_mem.edges, [2]int{g_mem.drag_vertex_index, drag_end_vertex_index})
						append(&g_mem.selected_edges, len(g_mem.edges) - 1)
					}
				}
				g_mem.dragging = false
			}
		}
	}

	// Right mouse - multiselect
	if rl.IsMouseButtonPressed(.RIGHT) && mouse_x_within_canvas && !g_mem.dragging {
		clear(&g_mem.selected_vertices)
		clear(&g_mem.selected_edges)
		g_mem.dragging = true
		g_mem.drag_start = mouse_world_position
		g_mem.drag_vertex_index = vertex_under_mouse
		g_mem.drag_left = false
	}
	if rl.IsMouseButtonReleased(.RIGHT) && g_mem.dragging && !g_mem.drag_left {
		if g_mem.mode == .Edge {
			for edge, i in g_mem.edges {
				edge_vector := g_mem.vertices[edge[1]].position - g_mem.vertices[edge[0]].position
				x_t : [2]f32 = { min(f32), max(f32) }
				if abs(edge_vector.x) > 1e-6 {
					t_0 := (min(g_mem.drag_start.x, mouse_world_position.x) - g_mem.vertices[edge[0]].position.x) / edge_vector.x
					t_1 := (max(g_mem.drag_start.x, mouse_world_position.x) - g_mem.vertices[edge[0]].position.x) / edge_vector.x
					if t_0 < t_1 {
						x_t = { t_0, t_1 }
					} else {
						x_t = { t_1, t_0 }
					}
				} else if g_mem.vertices[edge[0]].position.x < min(g_mem.drag_start.x, mouse_world_position.x) || 
					max(g_mem.drag_start.x, mouse_world_position.x) < g_mem.vertices[edge[0]].position.x {
					continue
				}
				y_t : [2]f32 = { min(f32), max(f32) }
				if abs(edge_vector.y) > 1e-6 {
					t_0 := (min(g_mem.drag_start.y, mouse_world_position.y) - g_mem.vertices[edge[0]].position.y) / edge_vector.y
					t_1 := (max(g_mem.drag_start.y, mouse_world_position.y) - g_mem.vertices[edge[0]].position.y) / edge_vector.y
					if t_0 < t_1 {
						y_t = { t_0, t_1 }
					} else {
						y_t = { t_1, t_0 }
					}
				} else if g_mem.vertices[edge[0]].position.y < min(g_mem.drag_start.y, mouse_world_position.y) || 
					max(g_mem.drag_start.y, mouse_world_position.y) < g_mem.vertices[edge[0]].position.y {
					continue
				}
				t_min := min(f32)
				t_max := max(f32)
				if (x_t[0] < y_t[0]) {
					if (y_t[0] > x_t[1]) {
						continue
					}
					t_min = y_t[0]
					t_max = x_t[1]
				} else {
					if (x_t[0] > y_t[1]) {
						continue
					}
					t_min = x_t[0]
					t_max = y_t[1]
				}
				if !(0 > t_max || 1 < t_min) {
					append(&g_mem.selected_edges, i)
				}
			}
		} else {
			for vertex, i in g_mem.vertices {
				if min(g_mem.drag_start.x, mouse_world_position.x) <= vertex.position.x &&
				vertex.position.x <= max(g_mem.drag_start.x, mouse_world_position.x) &&
				min(g_mem.drag_start.y, mouse_world_position.y) <= vertex.position.y &&
				vertex.position.y <= max(g_mem.drag_start.y, mouse_world_position.y) {
					append(&g_mem.selected_vertices, i)
					g_mem.vertices[i].velocity = {0.0, 0.0}
				}
			}
			slice.sort(g_mem.selected_vertices[:])
		}
		g_mem.dragging = false
	}

	if rl.IsKeyPressed(.DELETE) && !g_mem.dragging {
		// We remove selected edges and vertices.
		// We maintain the order of vertices.
		// We don't maintain the order of edges.
		slice.reverse_sort(g_mem.selected_edges[:])
		for edge in g_mem.selected_edges {
			unordered_remove(&g_mem.edges, edge)
		}

		i := 0
		for i < len(g_mem.edges) {
			edge := g_mem.edges[i]
			index1, found1 := slice.binary_search(g_mem.selected_vertices[:], edge[0])
			index2, found2 := slice.binary_search(g_mem.selected_vertices[:], edge[1])
			if found1 || found2 {
				unordered_remove(&g_mem.edges, i)
			} else {
				// Set the new indices of the vertices
				g_mem.edges[i][0] -= index1
				g_mem.edges[i][1] -= index2
				i += 1
			}
		}
		for v, i in g_mem.selected_vertices {
			delete(g_mem.vertices[v].text)
			end := len(g_mem.vertices)
			if i < len(g_mem.selected_vertices) - 1 {
				end = g_mem.selected_vertices[i + 1]
			}
			for j := v + 1; j < end; j += 1 {
				g_mem.vertices[j - i - 1] = g_mem.vertices[j]
			}
		}
		resize(&g_mem.vertices, len(g_mem.vertices) - len(g_mem.selected_vertices))

		clear(&g_mem.selected_vertices)
		clear(&g_mem.selected_edges)

		vertex_under_mouse = -1
		for i := len(g_mem.vertices) - 1; i > -1; i -= 1 {
			if linalg.distance(g_mem.vertices[i].position, mouse_world_position) < 10 {
				vertex_under_mouse = i
				break
			}
		}
	}

	if rl.IsFileDropped() && mouse_x_within_canvas {
		files := rl.LoadDroppedFiles()
		if files.count > 0 {
			filepath := string(files.paths[0])
			if json_data, ok := os.read_entire_file(filepath); ok {
				defer delete(json_data)
				graph_file: GraphFile
				if json.unmarshal(json_data, &graph_file) == nil {
					defer {
						for vertex in graph_file.vertices {
							delete(vertex)
						}
						delete(graph_file.vertices)
						delete(graph_file.edges)
					}
					valid_edges := true
					for edge in graph_file.edges {
						if edge[0] < 0 || len(graph_file.vertices) <= edge[0] ||
							edge[1] < 0 || len(graph_file.vertices) <= edge[1] {
								valid_edges = false
								break
						}
					}
					if valid_edges {
						g_mem.dragging = false
						clear(&g_mem.selected_vertices)
						clear(&g_mem.selected_edges)
						for vertex in g_mem.vertices {
							delete(vertex.text)
						}
						clear(&g_mem.vertices)
						clear(&g_mem.edges)
						// https://observablehq.com/@mbostock/phyllotaxis
						spacing : f32 = 20.0
						theta := math.PI * (3 - math.sqrt(f32(5)))
						for vertex, i in graph_file.vertices {
							r := spacing * math.sqrt(f32(i) + 0.5)
							a := (f32(i) + 0.5) * theta
							x := r * math.cos(a)
							y := r * math.sin(a)
							append(&g_mem.vertices, Vertex {
								position = {x, y},
								text = strings.clone_to_cstring(vertex)
							})
						}
						for edge in graph_file.edges {
							append(&g_mem.edges, edge)
						}
						vertex_under_mouse = -1
						for i := len(g_mem.vertices) - 1; i > -1; i -= 1 {
							if linalg.distance(g_mem.vertices[i].position, mouse_world_position) < 10 {
								vertex_under_mouse = i
								break
							}
						}
					}
				}
			}
		}
		rl.UnloadDroppedFiles(files)
	}

	if g_mem.apply_force {
		dt := min(rl.GetFrameTime(), 1 / 30.0) * 20.0
		for _ in 0..<10 {
			// Construct quad tree
			clear(&g_mem.quadtree)
			clear(&g_mem.quadtree_positions)
			min_x := max(f32)
			max_x := min(f32)
			min_y := max(f32)
			max_y := min(f32)
			for vertex, i in g_mem.vertices {
				append(&g_mem.quadtree_positions, vertex.position)
				min_x = min(vertex.position.x, min_x)
				max_x = max(vertex.position.x, max_x)
				min_y = min(vertex.position.y, min_y)
				max_y = max(vertex.position.y, max_y)
			}
			root := create_barnes_hut_tree(&g_mem.quadtree, { min_x, min_y }, { max_x - min_x, max_y - min_y }, g_mem.quadtree_positions[:])

			for i in 0..<len(g_mem.vertices) {
				g_mem.vertices[i].acceleration = -0.05 * g_mem.vertices[i].velocity
			}
			for i in 0..<len(g_mem.vertices) {
				force := 0.1 * inverse_distance_from_position(g_mem.quadtree[:], root, g_mem.vertices[i].position)
				g_mem.vertices[i].acceleration -= force
			}
			for edge in g_mem.edges {
				i := edge[0]
				j := edge[1]
				displacement := g_mem.vertices[j].position - g_mem.vertices[i].position
				force := 0.001 * (50 - linalg.length(displacement)) * linalg.normalize0(displacement)
				g_mem.vertices[j].acceleration += force
				g_mem.vertices[i].acceleration -= force
			}
			for i in 0..<len(g_mem.vertices) {
				_, found := slice.binary_search(g_mem.selected_vertices[:], i)
				if !found {
					g_mem.vertices[i].velocity += g_mem.vertices[i].acceleration * dt
					g_mem.vertices[i].position += g_mem.vertices[i].velocity * dt
				}
			}
		}

		vertex_under_mouse = -1
		for i := len(g_mem.vertices) - 1; i > -1; i -= 1 {
			if linalg.distance(g_mem.vertices[i].position, mouse_world_position) < 10 {
				vertex_under_mouse = i
				break
			}
		}
	}

	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)

	// Graph drawing
	rl.BeginMode2D(game_camera())

	for edge in g_mem.edges {
		rl.DrawLineV(g_mem.vertices[edge[0]].position, g_mem.vertices[edge[1]].position, rl.WHITE)
	}
	// Edge to be created
	if g_mem.dragging && g_mem.mode == .Edge && g_mem.drag_left {
		assert(g_mem.drag_vertex_index > -1)
		rl.DrawLineV(g_mem.vertices[g_mem.drag_vertex_index].position, mouse_world_position, rl.WHITE)
	}
	for edge in g_mem.selected_edges {
		edge := g_mem.edges[edge]
		rl.DrawLineV(g_mem.vertices[edge[0]].position, g_mem.vertices[edge[1]].position, rl.ORANGE)
	}

	for vertex in g_mem.vertices {
		rl.DrawPoly(vertex.position, 6, 10, 0, rl.WHITE)
	}
	if vertex_under_mouse > -1 {
		rl.DrawPoly(g_mem.vertices[vertex_under_mouse].position, 6, 10, 0, rl.YELLOW)
	}
	for vertex in g_mem.selected_vertices {
		rl.DrawPoly(g_mem.vertices[vertex].position, 6, 10, 0, rl.ORANGE)
	}

	if g_mem.dragging && !g_mem.drag_left {
		if g_mem.mode == .Edge {
			for edge, i in g_mem.edges {
				edge_vector := g_mem.vertices[edge[1]].position - g_mem.vertices[edge[0]].position
				x_t : [2]f32 = { min(f32), max(f32) }
				if abs(edge_vector.x) > 1e-6 {
					t_0 := (min(g_mem.drag_start.x, mouse_world_position.x) - g_mem.vertices[edge[0]].position.x) / edge_vector.x
					t_1 := (max(g_mem.drag_start.x, mouse_world_position.x) - g_mem.vertices[edge[0]].position.x) / edge_vector.x
					if t_0 < t_1 {
						x_t = { t_0, t_1 }
					} else {
						x_t = { t_1, t_0 }
					}
				} else if g_mem.vertices[edge[0]].position.x < min(g_mem.drag_start.x, mouse_world_position.x) || 
					max(g_mem.drag_start.x, mouse_world_position.x) < g_mem.vertices[edge[0]].position.x {
					continue
				}
				y_t : [2]f32 = { min(f32), max(f32) }
				if abs(edge_vector.y) > 1e-6 {
					t_0 := (min(g_mem.drag_start.y, mouse_world_position.y) - g_mem.vertices[edge[0]].position.y) / edge_vector.y
					t_1 := (max(g_mem.drag_start.y, mouse_world_position.y) - g_mem.vertices[edge[0]].position.y) / edge_vector.y
					if t_0 < t_1 {
						y_t = { t_0, t_1 }
					} else {
						y_t = { t_1, t_0 }
					}
				} else if g_mem.vertices[edge[0]].position.y < min(g_mem.drag_start.y, mouse_world_position.y) || 
					max(g_mem.drag_start.y, mouse_world_position.y) < g_mem.vertices[edge[0]].position.y {
					continue
				}
				t_min := min(f32)
				t_max := max(f32)
				if (x_t[0] < y_t[0]) {
					if (y_t[0] > x_t[1]) {
						continue
					}
					t_min = y_t[0]
					t_max = x_t[1]
				} else {
					if (x_t[0] > y_t[1]) {
						continue
					}
					t_min = x_t[0]
					t_max = y_t[1]
				}
				if !(0 > t_max || 1 < t_min) {
					rl.DrawLineV(g_mem.vertices[edge[0]].position, g_mem.vertices[edge[1]].position, rl.ORANGE)
				}
			}
		} else {
			for vertex, i in g_mem.vertices {
				if min(g_mem.drag_start.x, mouse_world_position.x) <= vertex.position.x &&
				vertex.position.x <= max(g_mem.drag_start.x, mouse_world_position.x) &&
				min(g_mem.drag_start.y, mouse_world_position.y) <= vertex.position.y &&
				vertex.position.y <= max(g_mem.drag_start.y, mouse_world_position.y) {
					rl.DrawPoly(g_mem.vertices[i].position, 6, 10, 0, rl.ORANGE)
				}
			}
		}
		rl.DrawRectangleV(
			{ min(g_mem.drag_start.x, mouse_world_position.x), min(g_mem.drag_start.y, mouse_world_position.y) },
			{ abs(g_mem.drag_start.x - mouse_world_position.x), abs(g_mem.drag_start.y - mouse_world_position.y) },
			{ 255, 161, 0, 25 }
		)
	}

	if g_mem.dragging && g_mem.mode == .Edge && g_mem.drag_left {
		assert(g_mem.drag_vertex_index > -1)
		rl.DrawPoly(g_mem.vertices[g_mem.drag_vertex_index].position, 6, 10, 0, rl.ORANGE)
	}

	if g_mem.apply_force {
		for node in g_mem.quadtree {
			rl.DrawLineV(node.position, node.position + { node.dimension.x, 0 }, rl.WHITE)
			rl.DrawLineV(node.position, node.position + { 0, node.dimension.y }, rl.WHITE)
			rl.DrawLineV(node.position + { 0, node.dimension.y }, node.position + node.dimension, rl.WHITE)
			rl.DrawLineV(node.position + { node.dimension.x, 0 }, node.position + node.dimension, rl.WHITE)
		}
	}

	rl.EndMode2D()

	// Note: main_hot_reload.odin clears the temp allocator at end of frame.
	// UI drawing
	rl.DrawRectangleV({0, 0}, {SIDEBAR_WIDTH, h}, {20, 20, 20, 255})
	rl.DrawRectangleV({w - SIDEBAR_WIDTH, 0}, {SIDEBAR_WIDTH, h}, {20, 20, 20, 255})

	text_y : f32 = 5.0
	rl.DrawTextEx(g_mem.font, fmt.ctprintf("FPS: %v", rl.GetFPS()), {5, text_y}, 28, 0, rl.WHITE)
	text_y += 30
	rl.DrawTextEx(g_mem.font, fmt.ctprintf("Vertices: %v", len(g_mem.vertices)), {5, text_y}, 28, 0, rl.WHITE)
	text_y += 30
	rl.DrawTextEx(g_mem.font, fmt.ctprintf("Edges: %v", len(g_mem.edges)), {5, text_y}, 28, 0, rl.WHITE)
	text_y += 30

	text_y += 20

	if rl.IsMouseButtonPressed(.LEFT) {
		// Check if a button was pressed.
		mouse_position := rl.GetMousePosition()
		if mouse_position.x <= SIDEBAR_WIDTH {
			y_index := int((mouse_position.y - text_y) / 35)
			if 0 <= y_index && y_index < 3 {
				g_mem.mode = Mode(y_index)
				g_mem.dragging = false
			}
		}
	}
	keys := [3]rl.KeyboardKey { .Q, .W, .E }
	for key, i in keys {
		if rl.IsKeyPressed(key) {
			g_mem.mode = Mode(i)
			g_mem.dragging = false
		}
	}

	modes := [3]cstring {"Move (Q)", "Vertex (W)", "Edge (E)"}
	for mode, i in modes {
		color := rl.WHITE
		if Mode(i) == g_mem.mode {
			color = rl.ORANGE
		}
		rl.DrawTextEx(g_mem.font, mode, {5, text_y}, 28, 0, color)
		text_y += 35
	}

	text_y += 20

	if rl.IsMouseButtonPressed(.LEFT) {
		// Check if a button was pressed.
		mouse_position := rl.GetMousePosition()
		if mouse_position.x <= SIDEBAR_WIDTH && 0 <= mouse_position.y - text_y && mouse_position.y - text_y < 35 {
			g_mem.apply_force = !g_mem.apply_force
			if g_mem.apply_force {
				for &vertex in g_mem.vertices {
					vertex.velocity = {0.0, 0.0}
				}
			}
		}
	}

	if g_mem.apply_force {
		rl.DrawTextEx(g_mem.font, "Pause forces", {5, text_y}, 28, 0, rl.WHITE)
	} else {
		rl.DrawTextEx(g_mem.font, "Apply forces", {5, text_y}, 28, 0, rl.WHITE)
	}

	// TODO: Add a textbox to edit text
	// rl.GuiSetFont(g_mem.font)
	// rl.GuiSetStyle(.DEFAULT, 16, 28)
	// rl.GuiTextBox({ w - SIDEBAR_WIDTH + 5, 5, SIDEBAR_WIDTH - 10, 35 }, cstring(&g_mem.text[0]), 1000, true)

	text_y = 5
	for vertex in g_mem.selected_vertices {
		rl.DrawTextEx(g_mem.font, g_mem.vertices[vertex].text, {w - SIDEBAR_WIDTH + 5, text_y}, 28, 0, rl.WHITE)
		text_y += 35
	}

	rl.EndDrawing()
	return !rl.WindowShouldClose()
}

@(export)
game_init_window :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(1280, 720, "Odin + Raylib + Hot Reload template!")
	rl.SetWindowPosition(200, 200)
	rl.SetTargetFPS(500)
}

@(export)
game_init :: proc() {
	g_mem = new(Game_Memory)

	font := rl.LoadFontEx("fonts/Inter/Inter_28pt-Medium.ttf", 28, nil, 250)
	g_mem^ = Game_Memory {
		camera_zoom = 1.0,
		font = font,
	}

	game_hot_reloaded(g_mem)
}

@(export)
game_shutdown :: proc() {
	for vertex in g_mem.vertices {
		delete(vertex.text)
	}
	delete(g_mem.vertices) // TODO: Is this correct?
	delete(g_mem.edges)
	delete(g_mem.selected_vertices)
	delete(g_mem.selected_edges)
	delete(g_mem.quadtree)
	delete(g_mem.quadtree_positions)
	free(g_mem)
}

@(export)
game_shutdown_window :: proc() {
	rl.CloseWindow()
}

@(export)
game_memory :: proc() -> rawptr {
	return g_mem
}

@(export)
game_memory_size :: proc() -> int {
	return size_of(Game_Memory)
}

@(export)
game_hot_reloaded :: proc(mem: rawptr) {
	g_mem = (^Game_Memory)(mem)
}

@(export)
game_force_reload :: proc() -> bool {
	return rl.IsKeyPressed(.F5)
}

@(export)
game_force_restart :: proc() -> bool {
	return rl.IsKeyPressed(.F6)
}
