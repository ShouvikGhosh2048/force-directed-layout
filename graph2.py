import random
import json

NUMBER_OF_VERTICES = 1000

vertices = [f"{i+1}" for i in range(NUMBER_OF_VERTICES)]
indices = [i for i in range(NUMBER_OF_VERTICES)]
random.shuffle(indices)
edges = []
for i in range(NUMBER_OF_VERTICES - 1):
    edges.append([indices[i], indices[i+1]])
edges.append([indices[-1], indices[0]])

with open("graph2.json", "w") as f:
    f.write(json.dumps({ "vertices": vertices, "edges": edges }))