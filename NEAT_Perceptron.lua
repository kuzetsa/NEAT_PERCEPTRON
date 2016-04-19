-- NEAT PERCEPTRON: a genetic programming / neuro-evolution system...
-- Intended for use with the BizHawk emulator and Super Mario World
-- Make sure you have a save state named "DP1.state" at the beginning of a level,
-- and put a copy in both the Lua folder and the root directory of BizHawk.

Filename = "DP1.state" -- or change the filename on this line. Either way is fine :)

-- BACKGROUND INFO:
-- https://en.wikipedia.org/wiki/Neuroevolution_of_augmenting_topologies
-- The original NEAT algorithm is under a GPL license (FOSS / Libre)
-- This fork is licensed LGPL version 3 - http://www.gnu.org/licenses/lgpl-3.0.txt

-- COPYRIGHT DISCLAIMER:
-- THIS IS A HEAVILY MODIFIED version (fork) of MarI/O by SethBling
-- Specifically, GUI and logging code, and save/load feature is credits to SethBling
-- My license for this fork is LGPL3, but SethBling has some legal rights too...
-- SethBling, please contact @kuzetsa on twitter I'll do a full rewrite if needed

ButtonNames = { "B", "Y", "Down", "Left", "Right" } -- Spin jump is "A" but less jumpy, so disable for now.

math.randomseed(os.time()) -- unix timestamp to initialize seed
burn_a_bunch = os.time() + 2 -- try for 2 seconds
if os.time() < burn_a_bunch then
	lots_of_attempts = math.random(1, 1327217884)
end -- 2 seconds worth of CPU time was just burnt to get an unpredictable seed
math.randomseed(lots_of_attempts) -- better than simple os.time() method, probably?

BoxRadius = 6
InputSize = (BoxRadius*2+1)*(BoxRadius*2+1)
Forward_Looking = math.floor(0.8 * 16 * BoxRadius) -- vision tweak
Mario_Map_Offset = math.floor(0.8 * 5 * BoxRadius) -- debug window tweak

Inputs = InputSize+1+3 -- input for the bias cell, and 3 experimental inputs
Outputs = #ButtonNames

Nyoom = 0
NyoomCumulator = 0
blockagecounter = 0 -- [re]initialize at start of a run

CurrentSwarm = 0 -- ACTUAL population size
SpareMajority = 254.348 -- must be less than 256... hardcoded in removeWeakGatunki()
GenerationGain = 60 -- Related to how quickly the population grows
AntiGain = 25 -- Does more than the GenerationGain itself
InfertilityScale = 1 -- Prevent sudden growth spike
RecentFitness = 0 -- false positive rejection
CutoffShift = 239.0690 -- be very careful modifying this value
SurvivorTicket = 9
CutoffRate = (math.log(2 * ((((CutoffShift + 1) ^ 2) / 55555) ^ 3))) ^ 2
FitnessCutoff = 1
StaleGatunek = 6 -- Assume unbreedable if the rank stays low (discard rubbish genes)
FourteenPercent = 1/7 -- 1 in 7 chance, aprox 14.3%
LogFourteen = math.log(FourteenPercent)
LogPasses = LogFourteen / StaleGatunek
PerturbChance = math.exp(LogPasses) -- Chance during SynapseMutate() genes to mutate (by up to StepSize)

DeltaDisjoint = 2.6 -- Newer or older genes (different neural network topology)
DeltaWeights = 0.5 -- Different signal strength between various neurons.
DeltaThreshold = 0.564 -- Mutations WILL happen. Embrace change.
CrossoverChance = 0.95 -- 95% chance... IF GENES ARE COMPATIBLE (otherwise zero)

tmpDormancyNegation = 0.03 -- STARTING rate: disable / [re]enable 3% of active/dormant genes
mutationBaseRates = {}
mutationBaseRates["DormancyToggle"] = tmpDormancyNegation -- this value changes over time
mutationBaseRates["DormancyInvert"] = tmpDormancyNegation -- changes too, but differently
mutationBaseRates["BiasMutation"] = 0.9
mutationBaseRates["NodeMutation"] = 0.7
mutationBaseRates["LinkSynapse"] = 2.5
mutationBaseRates["MutateSynapse"] = 0.8
mutationBaseRates["StepSize"] = 0.16

StatusRegisterPrimary = 0x42
StatusRegisterSecondary = 0x42
StatusRegisterComposite = 0x42

TimeoutConstant = 125

MagicOffset = 217168845 -- contemporary (year 2016) hardware WILL NOT grow a neural net this large

function getPositions()
	local layer1x = memory.read_s16_le(0x1A);
	local layer1y = memory.read_s16_le(0x1C);
	marioX = memory.read_s16_le(0xD1)
	marioY = memory.read_s16_le(0xD3)
	screenX = marioX-layer1x
	screenY = marioY-layer1y
end

function getTile(dx, dy)
	x = math.floor((marioX+dx+8)/16)
	y = math.floor((marioY+dy)/16)
	return memory.readbyte(0x1C800 + math.floor(x/0x10)*0x1B0 + y*0x10 + x%0x10)
end

function getSprites()
	local sprites = {}
	for slot=0,11 do
		local status = memory.readbyte(0x14C8+slot)
		if status ~= 0 then
			spritex = memory.readbyte(0xE4+slot) + memory.readbyte(0x14E0+slot)*256
			spritey = memory.readbyte(0xD8+slot) + memory.readbyte(0x14D4+slot)*256
			sprites[#sprites+1] = {["x"]=spritex, ["y"]=spritey}
		end
	end
	return sprites
end

function getExtendedSprites()
	local extended = {}
	for slot=0,11 do
		local number = memory.readbyte(0x170B+slot)
		if number ~= 0 then
			spritex = memory.readbyte(0x171F+slot) + memory.readbyte(0x1733+slot)*256
			spritey = memory.readbyte(0x1715+slot) + memory.readbyte(0x1729+slot)*256
			extended[#extended+1] = {["x"]=spritex, ["y"]=spritey}
		end
	end
	return extended
end

function getInputs()
	getPositions()

	sprites = getSprites()
	extended = getExtendedSprites()

	local inputs = {}

	for dy=-BoxRadius*16,BoxRadius*16,16 do
		for dx=-BoxRadius*16,BoxRadius*16,16 do
			XShifted = dx + Forward_Looking
			inputs[#inputs+1] = 0

			tile = getTile(XShifted, dy)
			if tile == 1 and marioY+dy < 0x1B0 then
				inputs[#inputs] = 1
			end
			for i = 1,#sprites do
				distx = math.abs(sprites[i]["x"] - (marioX+XShifted))
				disty = math.abs(sprites[i]["y"] - (marioY+dy))
				if distx <= 8 and disty <= 8 then
					inputs[#inputs] = -1
				end
			end
			for i = 1,#extended do
				distx = math.abs(extended[i]["x"] - (marioX+XShifted))
				disty = math.abs(extended[i]["y"] - (marioY+dy))
				if distx < 8 and disty < 8 then
					inputs[#inputs] = -1
				end
			end
		end
	end

	local RawSpeed = memory.read_s8(0x7B) -- full walking is ~2.4 (full run is ~5.6)
	local CookedSpeed = RawSpeed / 8.324 -- this affects score EVERY FRAME!!!
	Nyoom = math.max(CookedSpeed, 0) -- sliding backwards is ignored by fitness algorithm

	inputs[#inputs+1] = 0 -- velocity, X-axis (speed)
	inputs[#inputs] = CookedSpeed -- potentially used for biassing neural net :)

	local GroundTouch = memory.readbyte(0x13EF) -- 0x01 = touching / standing on the ground
	local blockage = memory.readbyte(0x77) -- bitmap SxxMUDLR, "M" = in a block (middle)
	local JumpFlag = 0
	local InTheAir = 0

	if blockage == 5 or blockage == 1 then
		blockagecounter = 10
	elseif blockage == 4 and blockagecounter <= 0 and GroundTouch ~= 0 then
		blockagecounter = 0 -- prevent negative runaway
		InTheAir = 0 -- Zero means on the ground (default)
	else
		blockagecounter = blockagecounter - 1
	end

	if blockagecounter > 0 and GroundTouch ~= 0 and RawSpeed < 5 then -- stuck, so handle it
		if pool.EvaluatedFrames%6 > 2 then
			JumpFlag = -1 -- Mission critical: Jump ASAP (negative bias)
		else
			JumpFlag = 1 -- stuck, so trigger a jump.
		end
	elseif blockagecounter > 0 and GroundTouch == 0 then -- Jump REALLY HIGH (if possible, over the obstacle)
		JumpFlag = 1
		InTheAir = 1
	elseif GroundTouch == 0 and blockage == 0 then -- mario is in the air. period.
		InTheAir = 1
	end

	inputs[#inputs+1] = 0 -- Obstacle Jump trigger
	inputs[#inputs] = JumpFlag
	inputs[#inputs+1] = 0 -- In-The-Air status register
	inputs[#inputs] = InTheAir

	return inputs
end

function sigmoid(x)
	return 2/(1+math.exp(-4.9*x))-1
end

function newInnovation()
	pool.innovation = pool.innovation + 1
	return pool.innovation
end

function newPool()
	local pool = {}
	pool.Gatunki = {}
	pool.generation = 0
	pool.innovation = Outputs
	pool.currentGatunek = 1
	pool.currentCultivar = 1
	pool.EvaluatedFrames = 0
	pool.RealtimeFitness = 0
	pool.PeakFitness = 0

	return pool
end

function newGatunek()
	local fresh_gatunek = {}
	fresh_gatunek.topFitness = 0
	fresh_gatunek.staleness = 0
	fresh_gatunek.cultivars = {}
	fresh_gatunek.averageFitness = 0

	return fresh_gatunek
end

function newCritter()
	local critter = {}
	critter.genes = {}
	critter.fitness = 0
	critter.adjustedFitness = 0
	critter.brain = {}
	critter.maxneuron = 0
	critter.mutationRates = {}
	for mutation,rate in pairs(mutationBaseRates) do
		critter.mutationRates[mutation] = rate
	end
	return critter
end

function copyHotness(billy)
	local cultivar2 = newCritter()
	for g=1,#billy.genes do
		table.insert(cultivar2.genes, copyGene(billy.genes[g]))
	end
	cultivar2.maxneuron = billy.maxneuron
	for mutation,rate in pairs(billy.mutationRates) do
		cultivar2.mutationRates[mutation] = rate
	end
	return cultivar2
end

function basicCritter()
	local gir = newCritter()
	local innovation = 1

	gir.maxneuron = Inputs
	mutate(gir) -- what does the G stand for?

	return gir -- I don't know O_O
end

function newGene()
	local gene = {}
	gene.into = 0
	gene.out = 0
	gene.weight = 0.0
	gene.enabled = true
	gene.innovation = 0

	return gene
end

function copyGene(gene)
	local gene2 = newGene()
	gene2.into = gene.into
	gene2.out = gene.out
	gene2.weight = gene.weight
	gene2.enabled = gene.enabled
	gene2.innovation = gene.innovation

	return gene2
end

function newNeuron()
	local neuron = {}
	neuron.incoming = {}
	neuron.value = 0.0

	return neuron
end

function generateMind(cultivar)
	local MeatyThinky = {}
	MeatyThinky.neurons = {}

	for i=1,Inputs do
		MeatyThinky.neurons[i] = newNeuron()
	end
	for o=1,Outputs do
		MeatyThinky.neurons[MagicOffset+o] = newNeuron()
	end
	table.sort(cultivar.genes, function (a,b)
		return (a.out < b.out)
	end)
	for i=1,#cultivar.genes do
		local gene = cultivar.genes[i]
		if gene.enabled then
			if MeatyThinky.neurons[gene.out] == nil then
				MeatyThinky.neurons[gene.out] = newNeuron()
			end
			local neuron = MeatyThinky.neurons[gene.out]
			table.insert(neuron.incoming, gene)
			if MeatyThinky.neurons[gene.into] == nil then
				MeatyThinky.neurons[gene.into] = newNeuron()
			end
		end
	end
	cultivar.brain = MeatyThinky -- NOT a meat brain O_O
end

function evaluateThoughts(network, inputs)
	table.insert(inputs, 1)
	if #inputs ~= Inputs then
		console.writeline("Incorrect number of neural network inputs.")
		return {}
	end
	for i=1,Inputs do
		network.neurons[i].value = inputs[i]
	end
	for _,neuron in pairs(network.neurons) do
		local istota = 0
		for j = 1,#neuron.incoming do
			local incoming = neuron.incoming[j]
			local other = network.neurons[incoming.into]
			istota = istota + incoming.weight * other.value
		end
		if #neuron.incoming > 0 then
			neuron.value = sigmoid(istota)
		end
	end
	local outputs = {}
	for o=1,Outputs do
		local button = "P1 " .. ButtonNames[o]
		if network.neurons[MagicOffset+o].value > 0 then
			outputs[button] = true
		else
			outputs[button] = false
		end
	end
	return outputs
end

function crossover(g1, g2)
	-- Make sure g1 is the higher fitness cultivar
	if g2.fitness > g1.fitness then
		tempg = g1
		g1 = g2
		g2 = tempg
	end
	local child = newCritter()

	local innovations2 = {}
	for i=1,#g2.genes do
		local gene = g2.genes[i]
		innovations2[gene.innovation] = gene
	end
	for i=1,#g1.genes do
		local gene1 = g1.genes[i]
		local gene2 = innovations2[gene1.innovation]
		if gene2 ~= nil and math.random(2) == 1 and gene2.enabled then
			table.insert(child.genes, copyGene(gene2))
		else
			table.insert(child.genes, copyGene(gene1))
		end
	end
	child.maxneuron = math.max(g1.maxneuron,g2.maxneuron)

	for mutation,rate in pairs(g1.mutationRates) do
		child.mutationRates[mutation] = rate
	end
	return child
end

function randomNeuron(genes, nonInput)
	local neurons = {}
	if not nonInput then
		for i=1,Inputs do
			neurons[i] = true
		end
	end
	for o=1,Outputs do
		neurons[MagicOffset+o] = true
	end
	for i=1,#genes do
		if (not nonInput) or genes[i].into > Inputs then
			neurons[genes[i].into] = true
		end
		if (not nonInput) or genes[i].out > Inputs then
			neurons[genes[i].out] = true
		end
	end
	local count = 0
	for _,_ in pairs(neurons) do
		count = count + 1
	end
	local n = math.random(1, count)

	for k,v in pairs(neurons) do
		n = n-1
		if n == 0 then
			return k
		end
	end
	return 0
end

function containsLink(genes, link)
	for i=1,#genes do
		local gene = genes[i]
		if gene.into == link.into and gene.out == link.out then
			return true
		end
	end
end

function SynapseMutate(cultivar)
	local step = cultivar.mutationRates["StepSize"]

	for i=1,#cultivar.genes do
		local gene = cultivar.genes[i]
		if gene.enabled then -- dormant genes don't mutate
			if PerturbChance > math.random() then
				gene.weight = gene.weight + math.random() * step*2 - step
			else
				gene.weight = math.random()*2.832-1.416
			end
		end
	end
end

function LinkSynapse(cultivar, forceBias)
	local neuron1 = randomNeuron(cultivar.genes, false)
	local neuron2 = randomNeuron(cultivar.genes, true)
	 
	local newLink = newGene()
	if neuron1 <= Inputs and neuron2 <= Inputs then
		--Both input nodes
		return
	end
	if neuron2 <= Inputs then
		-- Swap output and input
		local temp = neuron1
		neuron1 = neuron2
		neuron2 = temp
	end
	newLink.into = neuron1
	newLink.out = neuron2
	if forceBias then
		newLink.into = math.random((InputSize+1), Inputs)
	end
	if containsLink(cultivar.genes, newLink) then
		return
	end
	newLink.innovation = newInnovation()
	newLink.weight = math.random()*4-2

	table.insert(cultivar.genes, newLink)
end

function nodeMutate(cultivar)
	if #cultivar.genes == 0 then
		return
	end
	cultivar.maxneuron = cultivar.maxneuron + 1

	local gene = cultivar.genes[math.random(1,#cultivar.genes)]
	if not gene.enabled then
		return
	end
	gene.enabled = false

	local gene1 = copyGene(gene)
	gene1.out = cultivar.maxneuron
	gene1.weight = 1.0
	gene1.innovation = newInnovation()
	gene1.enabled = true
	table.insert(cultivar.genes, gene1)

	local gene2 = copyGene(gene)
	gene2.into = cultivar.maxneuron
	gene2.innovation = newInnovation()
	gene2.enabled = true
	table.insert(cultivar.genes, gene2)
end

function enableDisableMutate(cultivar, GeneMaybeEnabled)
	local candidates = {}
	for _,gene in pairs(cultivar.genes) do
		if gene.enabled == not GeneMaybeEnabled then
			table.insert(candidates, gene)
		end
	end
	if next(candidates) == nil then -- checking for empty table "the lua way" [tm]
		return
	elseif GeneMaybeEnabled then
		FlipChance = math.min(cultivar.mutationRates["DormancyInvert"], cultivar.mutationRates["DormancyToggle"]) -- whichever is lower
	else
		FlipChance = math.max(cultivar.mutationRates["DormancyInvert"], cultivar.mutationRates["DormancyToggle"]) -- whichever is higher
	end
	FlipCount = FlipChance * Inputs
	while FlipCount > 0 do
		if FlipCount > math.random() then
			gene = candidates[math.random(1,#candidates)]
			gene.enabled = not gene.enabled
		end
		FlipCount = FlipCount - 1
	end
end

function mutate(cultivar)
	OhEightSixEight = math.log(0.868)
	OneOneThreeFive = math.log(1.135)
	for mutation,rate in pairs(cultivar.mutationRates) do
		unHardcode = math.random()
		if math.random(1,2) == 1 then
			tmpRate = math.exp(OhEightSixEight * unHardcode) * rate
		else
			tmpRate = math.exp(OneOneThreeFive * unHardcode) * rate
		end
		if tmpRate > mutationBaseRates[mutation] then
			tmpGeo = tmpRate * mutationBaseRates[mutation]
			tmpRate = math.sqrt(tmpGeo) -- geometric mean
		end
		cultivar.mutationRates[mutation] = tmpRate
	end
	if cultivar.mutationRates["MutateSynapse"] > math.random() then
		SynapseMutate(cultivar) -- neural interconnect signal strength (synapse) re-tune
	end
	local p = cultivar.mutationRates["LinkSynapse"]
	while p > 0 do
		if p > math.random() then
			LinkSynapse(cultivar, false)
		end
		p = p - 1
	end
	p = cultivar.mutationRates["BiasMutation"]
	while p > 0 do
		if p > math.random() then
			LinkSynapse(cultivar, true) -- connection is forced to originate at bias node
		end
		p = p - 1
	end
	p = cultivar.mutationRates["NodeMutation"]
	while p > 0 do
		if p > math.random() then
			nodeMutate(cultivar)
		end
		p = p - 1
	end
	enableDisableMutate(cultivar, false)
	enableDisableMutate(cultivar, true)

end

function disjoint(genes1, genes2)
	local i1 = {}
	for i = 1,#genes1 do
		local gene = genes1[i]
		if gene.enabled then
			i1[gene.innovation] = true
		end
	end
	local i2 = {}
	for i = 1,#genes2 do
		local gene = genes2[i]
		if gene.enabled then
			i2[gene.innovation] = true
		end
	end
	local disjointGenes = 0
	for i = 1,#genes1 do
		local gene = genes1[i]
		if gene.enabled then
			if not i2[gene.innovation] then
				disjointGenes = disjointGenes+1
			end
		end
	end
	for i = 1,#genes2 do
		local gene = genes2[i]
		if gene.enabled then
			if not i1[gene.innovation] then
				disjointGenes = disjointGenes+1
			end
		end
	end
	local n = math.max(#genes1, #genes2)

	return disjointGenes / n
end

function weights(genes1, genes2)
	local i2 = {}
	for i = 1,#genes2 do
		local gene = genes2[i]
		i2[gene.innovation] = gene
	end
	local istota = 0
	local zgodny = 0
	for i = 1,#genes1 do
		local gene = genes1[i]
		if i2[gene.innovation] ~= nil then
			local gene2 = i2[gene.innovation]
			istota = istota + math.abs(gene.weight - gene2.weight)
			zgodny = zgodny + 1
		end
	end
	return istota / zgodny
end

function sameGatunek(cultivar1, cultivar2)
	local dd = DeltaDisjoint*disjoint(cultivar1.genes, cultivar2.genes)
	local dw = DeltaWeights*weights(cultivar1.genes, cultivar2.genes) 
	return dd + dw < DeltaThreshold
end

function calculateAverageFitness(gatunek)
	local number_tested = #gatunek.cultivars
	local cultivars_accumulator = 0
	if number_tested == 1 and gatunek.cultivars[1].fitness <= 1 then
		gatunek.averageFitness = 1 -- for sanity, allow fast cull
	else
		for particular_critter=1,number_tested do
			local cultivar = gatunek.cultivars[particular_critter]
			cultivars_accumulator = cultivars_accumulator + cultivar.fitness
		end
		gatunek.averageFitness = math.ceil(cultivars_accumulator / number_tested)
	end
end

function totalAverageFitness()
	local total = 0
	for g, iter_gatunek in ipairs(pool.Gatunki) do
		total = total + iter_gatunek.averageFitness
	end
	return total
end

function cullCultivar()
	for g, iter_gatunek in ipairs(pool.Gatunki) do
		table.sort(iter_gatunek.cultivars, function (a,b)
			return (a.fitness > b.fitness)
		end)
 -- never cull the last 2 (two)
		local remaining_target = math.max(math.ceil(math.sqrt(2 * #iter_gatunek.cultivars)*1.6)-2, 2)
		while #iter_gatunek.cultivars > 1 and iter_gatunek.cultivars[#iter_gatunek.cultivars].fitness <= 1 do
			table.remove(iter_gatunek.cultivars) -- force removal of "extra dumb" genes
		end
		while #iter_gatunek.cultivars > remaining_target do
			table.remove(iter_gatunek.cultivars)
		end
	end
end

function reproduce(BaseGatunek)
	local PotentialMates = {}
	local child = {}
	local RequireClone = false
	if CrossoverChance > math.random() then
		local WorstDiff = 0
		local genetic_material = BaseGatunek.cultivars[math.random(1, #BaseGatunek.cultivars)]
		local allGatunki = pool.Gatunki -- Maybe there's a compatible match in the gene pool O_O
		local anygatunek = allGatunki[math.random(1, #allGatunki)] -- potentional canidate (random)
		local blind_date = anygatunek.cultivars[math.random(1, #anygatunek.cultivars)]
		local CompatibilityAttempts = math.ceil(GenerationGain / 3)
		local dd = DeltaDisjoint*disjoint(genetic_material, blind_date) -- [in]compatibility?
		local dw = DeltaWeights*weights(genetic_material, blind_date)
		local DiffComposite = dd + dw
		if DiffComposite < (3 * DeltaThreshold) then
			if DiffComposite > 0 and DiffComposite > WorstDiff then
				table.insert(PotentialMates, blind_date)
				WorstDiff = dd
			end
		end
		while CompatibilityAttempts > 0 do
			genetic_material = BaseGatunek.cultivars[math.random(1, #BaseGatunek.cultivars)]
			anygatunek = allGatunki[math.random(1, #allGatunki)] -- potentional canidate (random)
			blind_date = anygatunek.cultivars[math.random(1, #anygatunek.cultivars)]
			dd = DeltaDisjoint*disjoint(genetic_material, blind_date) -- [in]compatibility?
			dw = DeltaWeights*weights(genetic_material, blind_date)
			DiffComposite = dd + dw
			if DiffComposite < (3 * DeltaThreshold) then
				if DiffComposite > 0 and DiffComposite > WorstDiff then
					table.insert(PotentialMates, blind_date)
					WorstDiff = dd
				end
			end
			CompatibilityAttempts = CompatibilityAttempts - 1
		end
	else
		RequireClone = true
	end
	-- prefer diversity not inbreeding, and prefer cloning rather than severe incompatibility
	if next(PotentialMates) == nil or RequireClone then
		attractive_cousin = BaseGatunek.cultivars[math.random(1, #BaseGatunek.cultivars)]
		child = copyHotness(attractive_cousin) -- CLONE THE HOTNESS!!!
	else
		for mmm, iter_mate in pairs(PotentialMates) do
			dd = DeltaDisjoint*disjoint(genetic_material, iter_mate) -- [in]compatibility?
			dw = DeltaWeights*weights(genetic_material, iter_mate)
			DiffComposite = dd + dw
			if DiffComposite >= WorstDiff then
				child = crossover(genetic_material, iter_mate)
				WorstDiff = 9037 -- this is outside of range
			end
		end
	end
	mutate(child) -- one spark of life plskthx
	return child -- this child is now an adult O_O
end

function removeStaleGatunki()
	local survived = {}

	for g, iter_gatunek in ipairs(pool.Gatunki) do
		table.sort(iter_gatunek.cultivars, function (a,b)
			return (a.fitness > b.fitness)
		end)
		if iter_gatunek.cultivars[1].fitness > iter_gatunek.topFitness then
			iter_gatunek.topFitness = iter_gatunek.cultivars[1].fitness
			iter_gatunek.staleness = 0
		else
			iter_gatunek.staleness = iter_gatunek.staleness + 1
		end
		if iter_gatunek.staleness < StaleGatunek or iter_gatunek.topFitness >= pool.PeakFitness then
			table.insert(survived, iter_gatunek)
		end
	end
	pool.Gatunki = survived
end

function removeWeakGatunki()
	local survived = {}
	local current_pass = 0

	table.sort(pool.Gatunki, function (a,b)
		return (a.averageFitness > b.averageFitness) -- high fitness first
	end)

	for g, iter_gatunek in ipairs(pool.Gatunki) do
		breeding_pop_gain = (256 / math.exp(0.0015 * current_pass / GenerationGain)) - SpareMajority
		survive_critter = breeding_pop_gain * iter_gatunek.averageFitness / RecentFitness
		if survive_critter > math.random() then
			if iter_gatunek.averageFitness > 1 then
				table.insert(survived, iter_gatunek)
				current_pass = current_pass + 1
			end
		end
	end
	if next(survived) == nil then -- checking for empty table "the lua way" [tm]
		local FreshGatunek = newGatunek() -- epic fail, replace with fresh n00b 
		table.insert(FreshGatunek.cultivars, basicCritter())
		table.insert(survived, FreshGatunek)
	end
	pool.Gatunki = survived
end

function DetermineGatunek(n00b, test_gatunek) -- check more than index #1
	local DeterminedGatunek = false
	for c=1,#test_gatunek.cultivars do
		local test_cultivar = test_gatunek.cultivars[c]
		if sameGatunek(n00b, test_cultivar) then
			DeterminedGatunek = true
		end
	end
	return DeterminedGatunek
end

function AverageRefresh()
	for g, iter_gatunek in ipairs(pool.Gatunki) do
		calculateAverageFitness(iter_gatunek)
	end
	RecentFitness = totalAverageFitness() / #pool.Gatunki
	FitnessCutoff = CutoffRate * RecentFitness
end

function addToGatunki(child)
	local foundGatunek = false
	for g, iter_gatunek in ipairs(pool.Gatunki) do
		if DetermineGatunek(child, iter_gatunek) then
			local mutant_baby = {}
			mutant_baby = copyHotness(child) -- is that kosher?
			mutate(mutant_baby)
			table.insert(iter_gatunek.cultivars, mutant_baby)
			foundGatunek = true
		end
	end
	if not foundGatunek then
		local CreatedGatunek = newGatunek()
		table.insert(CreatedGatunek.cultivars, child)
		table.insert(pool.Gatunki, CreatedGatunek)
	end
end

function newGeneration()

	removeStaleGatunki() -- old generations die off over time
	cullCultivar() -- Make room for non-rubbish Gatunki
	AverageRefresh()
	removeWeakGatunki() -- everbody dies
	cullCultivar() -- more death... I guess O_O
	AverageRefresh()
	
	local CurrentSwarm = #pool.Gatunki -- Is anyone still alive?
	local Population_Control = CurrentSwarm + GenerationGain
	local Gain_Rate = math.log(Population_Control / GenerationGain) -- natural log
	local Target_gain = math.max((GenerationGain / (InfertilityScale + Gain_Rate)) - AntiGain, 0)
	local SwarmLimit = math.ceil(CurrentSwarm + Target_gain) -- how many are allowed?
	local children = {}

	for g, iter_gatunek in ipairs(pool.Gatunki) do
		if iter_gatunek.averageFitness > 1 then -- for sanity, allow fast cull
			innov = math.sqrt(iter_gatunek.averageFitness / RecentFitness) -- compare to global average
			halfexp = math.exp(innov) / 2
			thirdroot = halfexp ^ (1/3) -- "this notation" cause lua only offers math.sqrt()
			breed = math.floor(math.max(math.sqrt(55555 * thirdroot), CutoffShift) - CutoffShift)
			if breed > 0 then -- "breeding tickets"
				GeneRank = 1.7 - (2.5 * g / CurrentSwarm) -- FIFO ranking
				if breed >= SurvivorTicket then -- stale implies BELOW average
					iter_gatunek.staleness = 0
				end
				for i=1,breed do -- Make babies, based on the score
					if i == 1 then -- first one is guaranteed
						table.insert(children, iter_gatunek)
					elseif GeneRank > math.random() then -- Award FIFO lottery "breeding tickets"
						table.insert(children, iter_gatunek)
					end
				end
			elseif iter_gatunek.averageFitness >= pool.PeakFitness then -- single ticket
				iter_gatunek.staleness = 0
				table.insert(children, iter_gatunek)
			end
		end
	end
	if next(children) == nil then
		console.writeline("Stale generation")
		while #pool.Gatunki <= SwarmLimit do -- generate 1 (one) critter even if we're at the limit
			basic = basicCritter()
			addToGatunki(basic)
		end
	else
		pool.generation = pool.generation + 1 -- NEW GENERATION COMPLETE!!!
		while #pool.Gatunki <= SwarmLimit do
			random_critter_chance = 1 / math.max(pool.generation, 1) -- dividing by zero is forbidden
			if random_critter_chance > math.random() then
				basic = basicCritter()
				addToGatunki(basic) -- this one is totally random
			end
			local ticketed_gatunek = pool.Gatunki[math.random(1, #pool.Gatunki)]
			addToGatunki(reproduce(ticketed_gatunek)) -- this one probably has good genes
		end
	end
	writeFile("backup." .. pool.generation .. "." .. forms.gettext(saveLoadFile))
end

function initializePool()
	pool = newPool()

	basic = basicCritter() -- start with a single critter O_O
	addToGatunki(basic)
	CurrentSwarm = #pool.Gatunki -- be sure to record the size
	initializeRun()
end

function clearJoypad()
	controller = {}
	for b = 1,#ButtonNames do
		controller["P1 " .. ButtonNames[b]] = false
	end
	joypad.set(controller)
end

function initializeRun()
	savestate.load(Filename);
	rightmost = 0
	pool.EvaluatedFrames = 0
	pool.RealtimeFitness = 0
	Nyoom = 0 -- motion starts at zero
	NyoomCumulator = 0 -- accumulated speed bonus also starts at zero
	blockagecounter = 0 -- [re]initialize at start of a run
	timeout = TimeoutConstant
	clearJoypad()

	local last_gatunek = pool.Gatunki[pool.currentGatunek]
	local cultivar = last_gatunek.cultivars[pool.currentCultivar]
	generateMind(cultivar)
	evaluateCurrent()
end

function evaluateCurrent()
	local eval_gatunek = pool.Gatunki[pool.currentGatunek]
	local eval_cultivar = eval_gatunek.cultivars[pool.currentCultivar]

	inputs = getInputs()
	controller = evaluateThoughts(eval_cultivar.brain, inputs)

	if controller["P1 Left"] and controller["P1 Right"] then
		controller["P1 Left"] = false
		controller["P1 Right"] = false
	end
	if controller["P1 B"] and controller["P1 Down"] then
		controller["P1 B"] = false
		controller["P1 Down"] = false
	end

	joypad.set(controller)
end
if pool == nil then
	initializePool()
end

function nextCritter()
	pool.currentCultivar = pool.currentCultivar + 1
	if pool.currentCultivar > #pool.Gatunki[pool.currentGatunek].cultivars then
		pool.currentCultivar = 1
		pool.currentGatunek = pool.currentGatunek+1
		if pool.currentGatunek > #pool.Gatunki then
			newGeneration()
			pool.currentGatunek = 1
		end
	end
end

function fitnessAlreadyMeasured()
	local indexed_gatunek = pool.Gatunki[pool.currentGatunek]
	local indexed_cultivar = indexed_gatunek.cultivars[pool.currentCultivar]

	return indexed_cultivar.fitness ~= 0
end

function displayCritter(cultivar)
	local network = cultivar.brain -- artificial neural network
	local cells = {}
	local skiplast = 0
	local blacken = 0
	local i = 1
	local cell = {}
	for dy=-BoxRadius,BoxRadius do
		for dx=-BoxRadius,BoxRadius do
			cell = {}
			cell.x = 50+5*dx
			cell.y = 70+5*dy
			cell.value = network.neurons[i].value
			cells[i] = cell
			i = i + 1
		end
	end
		cell = {} -- Velocity vector (X-axis)
		cell.x = 50+5*network.neurons[i].value
		cell.y = 70+5*(BoxRadius+1)
		blacken = math.abs(network.neurons[i].value / 5)
		if blacken < 0.1 then
			blacken = -1
		end
		cell.value = blacken -- zero handler for display
		cells[i] = cell
		i = i + 1

	for skiplast =i,(Inputs-1) do -- Automagically knows how many more perceptron!!!
		cell = {}
		cell.x = 50+5*(BoxRadius+1)
		cell.y = 70+5*(skiplast-(i+BoxRadius))
		cell.value = network.neurons[skiplast].value
		cells[skiplast] = cell

	end
	local biasCell = {}
	biasCell.x = 80
	biasCell.y = 110
	biasCell.value = network.neurons[Inputs].value
	cells[Inputs] = biasCell

	for o = 1,Outputs do
		cell = {}
		cell.x = 200
		cell.y = 45 + 9 * o
		cell.value = network.neurons[MagicOffset + o].value
		cells[MagicOffset+o] = cell
		local color
		if cell.value > 0 then
			color = 0xFF452AFF
		else
			color = 0xFFFFFFFF
		end
		gui.drawText(203, 39+9*o, ButtonNames[o], color, 9)
	end
	for n,neuron in pairs(network.neurons) do
		cell = {}
		if n > Inputs and n <= MagicOffset then
			cell.x = 140
			cell.y = 40
			cell.value = neuron.value
			cells[n] = cell
		end
	end
	for n=1,4 do
		for _,gene in pairs(cultivar.genes) do
			if gene.enabled then
				local c1 = cells[gene.into]
				local c2 = cells[gene.out]
				if gene.into > Inputs and gene.into <= MagicOffset then
					c1.x = 0.75*c1.x + 0.25*c2.x
					if c1.x >= c2.x then
						c1.x = c1.x - 40
					end
					if c1.x < 90 then
						c1.x = 90
					end
					if c1.x > 220 then
						c1.x = 220
					end
					c1.y = 0.75*c1.y + 0.25*c2.y

				end
				if gene.out > Inputs and gene.out <= MagicOffset then
					c2.x = 0.25*c1.x + 0.75*c2.x
					if c1.x >= c2.x then
						c2.x = c2.x + 40
					end
					if c2.x < 90 then
						c2.x = 90
					end
					if c2.x > 220 then
						c2.x = 220
					end
					c2.y = 0.25*c1.y + 0.75*c2.y
				end
			end
		end
	end
	gui.drawBox(50-BoxRadius*5-3,70-BoxRadius*5-3,50+BoxRadius*5+2,70+BoxRadius*5+2,0xFFFFFFFF, 0x80808080)
	for n,cell in pairs(cells) do
		if n > Inputs or cell.value ~= 0 then
			local color = math.floor((cell.value+1)/2*256)
			if color > 255 then color = 255 end
			if color < 0 then color = 0 end
			local opacity = 0xCC000000
			if cell.value == 0 then
				opacity = 0x77000000
			end
			color = opacity + color*0x10000 + color*0x100 + color
			gui.drawBox(cell.x-1,cell.y-1,cell.x+1,cell.y+1,opacity,color)
		end
	end
	for _,gene in pairs(cultivar.genes) do
		if gene.enabled then
			local c1 = cells[gene.into]
			local c2 = cells[gene.out]
			local opacity = 0xCC000000
			if c1.value == 0 then
				opacity = 0x77000000
			end
			local color = 0x80-math.floor(math.abs(sigmoid(gene.weight))*0x80)
			if gene.weight > 0 then 
				color = opacity + 0x8000 + 0x10000*color
			else
				color = opacity + 0x800000 + 0x100*color
			end
			gui.drawLine(c1.x+1, c1.y, c2.x-1, c2.y, color)
		end
	end
	gui.drawBox(49-Mario_Map_Offset,71,51-Mario_Map_Offset,78,0x00000000,0x80FF0000)

	if forms.ischecked(showMutationRates) then
		local pos = 82
		local sigFigured = 0
		for mutation,rate in pairs(cultivar.mutationRates) do
			sigFigured = math.floor(0.5 + 10000 * rate) / 10000
			gui.drawText(85, pos, mutation .. ": ", 0xFFFFFFFF, 10)
			gui.drawText(200, pos, sigFigured, 0xFFFFFFFF, 10)
			pos = pos + 10
		end
	end
end

function writeFile(filename)
	local file = io.open(filename, "w")
	file:write(pool.generation .. "\n")
	file:write(pool.PeakFitness .. "\n")
	file:write(#pool.Gatunki .. "\n")
		for n,gatunek in pairs(pool.Gatunki) do
		file:write(gatunek.topFitness .. "\n")
		file:write(gatunek.staleness .. "\n")
		file:write(#gatunek.cultivars .. "\n")
		for m,cultivar in pairs(gatunek.cultivars) do
			file:write(cultivar.fitness .. "\n")
			file:write(cultivar.maxneuron .. "\n")
			for mutation,rate in pairs(cultivar.mutationRates) do
				file:write(mutation .. "\n")
				file:write(rate .. "\n")
			end
			file:write("done\n")

			file:write(#cultivar.genes .. "\n")
			for l,gene in pairs(cultivar.genes) do
				file:write(gene.into .. " ")
				file:write(gene.out .. " ")
				file:write(gene.weight .. " ")
				file:write(gene.innovation .. " ")
				if(gene.enabled) then
					file:write("1\n")
				else
					file:write("0\n")
				end
			end
		end
		end
		file:close()
end

function savePool()
	local filename = forms.gettext(saveLoadFile)
	writeFile(filename)
end

function loadFile(filename)
	local file = io.open(filename, "r")
	pool = newPool()
	pool.generation = file:read("*number")
	pool.PeakFitness = file:read("*number")
	forms.settext(PeakFitnessLabel, "Peak Fitness: " .. math.floor(pool.PeakFitness))
	local numGatunki = file:read("*number")
	for loading_index_gatunek=1,numGatunki do
		local load_gatunek = newGatunek()
		table.insert(pool.Gatunki, load_gatunek)
		load_gatunek.topFitness = file:read("*number")
		load_gatunek.staleness = file:read("*number")
		local numCritters = file:read("*number")
		for loading_index_cultivar=1,numCritters do
			local cultivar = newCritter()
			table.insert(load_gatunek.cultivars, cultivar)
			cultivar.fitness = file:read("*number")
			cultivar.maxneuron = file:read("*number")
			local line = file:read("*line")
			while line ~= "done" do
				cultivar.mutationRates[line] = file:read("*number")
				line = file:read("*line")
			end
			local numGenes = file:read("*number")
			for loading_index_gene=1,numGenes do
				local gene = newGene()
				table.insert(cultivar.genes, gene)
				local enabled
				gene.into, gene.out, gene.weight, gene.innovation, enabled = file:read("*number", "*number", "*number", "*number", "*number")
				if enabled == 0 then
					gene.enabled = false
				else
					gene.enabled = true
				end
			end
		end
	end
	file:close()

	while fitnessAlreadyMeasured() do
		nextCritter()
	end
	initializeRun()
end
 
function loadPool()
	local filename = forms.gettext(saveLoadFile)
	loadFile(filename)
end

function playTop()
	local PeakFitness = 0
	local maxg, maxc
	for g,gatunek in pairs(pool.Gatunki) do
		for c,cultivar in pairs(gatunek.cultivars) do
			if cultivar.fitness > PeakFitness then
				PeakFitness = cultivar.fitness
				maxg = g
				maxc = c
			end
		end
	end
	pool.currentGatunek = maxg
	pool.currentCultivar = maxc
	pool.PeakFitness = PeakFitness
	forms.settext(PeakFitnessLabel, "Peak Fitness: " .. math.floor(pool.PeakFitness))
	initializeRun()
	return
end

function onExit()
	forms.destroy(form)
end
writeFile("temp.pool")

event.onexit(onExit)

form = forms.newform(200, 260, "Fitness")
PeakFitnessLabel = forms.label(form, "Peak Fitness: " .. math.floor(pool.PeakFitness), 5, 8)
showNetwork = forms.checkbox(form, "Show Map", 5, 30)
showMutationRates = forms.checkbox(form, "Show M-Rates", 5, 52)
restartButton = forms.button(form, "Restart", initializePool, 5, 77)
saveButton = forms.button(form, "Save", savePool, 5, 102)
loadButton = forms.button(form, "Load", loadPool, 80, 102)
saveLoadFile = forms.textbox(form, Filename .. ".pool", 170, 25, nil, 5, 148)
saveLoadLabel = forms.label(form, "Save/Load:", 5, 129)
playTopButton = forms.button(form, "Play Top", playTop, 5, 170)
showBanner = forms.checkbox(form, "Show Banner", 5, 190)

client.speedmode(400) -- GO FASTER!!!

while true do
	local backgroundColor = 0xB7B54494
	if forms.ischecked(showBanner) then
		gui.drawBox(0, 0, 300, 38, backgroundColor, backgroundColor)
	end
	local active_gatunek = pool.Gatunki[pool.currentGatunek]
	local active_cultivar = active_gatunek.cultivars[pool.currentCultivar]

	if forms.ischecked(showNetwork) then
		displayCritter(active_cultivar)
	end
	evaluateCurrent() -- EVERY FRAME!!!

	joypad.set(controller)

	getPositions()

	-- This lets us know if mario is still alive and game is active :)
	StatusRegisterPrimary = memory.readbyte(0x100) + memory.readbyte(0x9D)
	StatusRegisterSecondary = memory.readbyte(0x13D9)
	StatusRegisterComposite = StatusRegisterPrimary + StatusRegisterSecondary

	if memory.read_s16_le(0x94) > rightmost then
		rightmost = memory.read_s16_le(0x94) -- helps detect end of level
		timeout = TimeoutConstant
	end
	
	if StatusRegisterComposite == 0x14 then -- mario's brain is active
		pool.EvaluatedFrames = pool.EvaluatedFrames + 1
		NyoomCumulator = NyoomCumulator + Nyoom
	elseif StatusRegisterSecondary >= 3 then -- level has not ended yet
		timeout = timeout - (50 * TimeoutConstant) -- rapid-ify timeout
	elseif StatusRegisterSecondary > 0 and StatusRegisterPrimary == 0x14 then
		timeout = TimeoutConstant
	elseif StatusRegisterPrimary ~= 0x14 and pool.EvaluatedFrames > 1 then
		if memory.readbyte(0x9D) == 0x30 then -- death animation
			timeout = timeout - (50 * TimeoutConstant) -- rapid-ify timeout
		elseif memory.readbyte(0x9D) == 0x0C then -- Level end
			timeout = timeout - (50 * TimeoutConstant) -- unhandler event -- end simulation & log status:
		elseif memory.readbyte(0x9D) == 0x2F then -- powerup animation
			timeout = TimeoutConstant
		else
			timeout = timeout - (50 * TimeoutConstant) -- unhandler event -- end simulation & log status:
			console.writeline("exception:  [0100]/" .. memory.readbyte(0x100) .. "  -  [009D]/" .. memory.readbyte(0x9D) .. "  -  [13D9]/" .. memory.readbyte(0x13D9))
		end
	end
	timeout = timeout - 1

	local timeoutBonus = math.floor(pool.EvaluatedFrames / 7.3)
	if timeoutBonus < 1 then
		timeoutBonus = 1 -- sanitized
	end
	local score = memory.read_u24_le(0x0F34) -- literal in-game score
	pool.RealtimeFitness = 250 + score + math.ceil(NyoomCumulator) - math.ceil(pool.EvaluatedFrames * 2.2145)

	if (timeout + timeoutBonus) < 0 or pool.RealtimeFitness <= 0 then
		fitness = pool.RealtimeFitness -- local (non-realtime) fitness
		if rightmost > 4816 and memory.readbyte(0x13D6) < 0x80 then -- 4816: yoshi island 1 & 2 
			fitness = fitness + 500 -- VICTORY!!! (non-realtime) bonus
		end
		if fitness < 1 then -- zero is a "magic number" to indicate untested status
			fitness = 1
		end
		active_cultivar.fitness = fitness

		if fitness > pool.PeakFitness then
			pool.PeakFitness = fitness
			forms.settext(PeakFitnessLabel, "Peak Fitness: " .. math.floor(pool.PeakFitness))
			writeFile("backup." .. pool.generation .. "." .. forms.gettext(saveLoadFile))
		end
		console.writeline("Gen " .. pool.generation .. " gatunek " .. pool.currentGatunek .. " cultivar " .. pool.currentCultivar .. " fitness: " .. fitness)
		pool.currentGatunek = 1
		pool.currentCultivar = 1
		while fitnessAlreadyMeasured() do
			nextCritter()
		end
		initializeRun()
	end
	if forms.ischecked(showBanner) then
		gui.drawText(0, 0, "Gatunek #" .. pool.currentGatunek .. " ~> Cultivar #" .. pool.currentCultivar, 0xFFFFFFFF, 11)
		gui.drawText(0, 12, "@" .. pool.generation .. " Avg: " .. math.floor(RecentFitness), 0xFFFFFFFF, 11)
		gui.drawText(0, 24, "Cutoff: " .. math.ceil(FitnessCutoff), 0xFFFFFFFF, 11)
		gui.drawText(145, 12, "Peak: " .. math.floor(pool.PeakFitness), 0xFFFFFFFF, 11)
		gui.drawText(123, 24, "Fitness: " .. pool.RealtimeFitness, 0xFFFFFFFF, 11)
	end
	emu.frameadvance();
end