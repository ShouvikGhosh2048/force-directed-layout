import random
import json

NUMBER_OF_VERTICES = 1000

vertices = [f"{i+1}" for i in range(NUMBER_OF_VERTICES)]
community1 = []
community2 = []
for v in range(NUMBER_OF_VERTICES):
    if random.random() < 0.5:
        community1.append(v)
    else:
        community2.append(v)

edges = []
for i in range(len(community1)):
    for j in range(i+1, len(community1)):
        if random.random() < 0.01:
            edges.append([community1[i], community1[j]])
for i in range(len(community2)):
    for j in range(i+1, len(community2)):
        if random.random() < 0.01:
            edges.append([community2[i], community2[j]])
for i in range(len(community1)):
    for j in range(len(community2)):
        if random.random() < 0.001:
            edges.append([community1[i], community2[j]])

with open("graph.json", "w") as f:
    f.write(json.dumps({ "vertices": vertices, "edges": edges }))