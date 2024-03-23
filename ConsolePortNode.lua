----------------------------------------------------------------
-- ConsolePortNode
----------------------------------------------------------------
-- 
-- Author:  Sebastian Lindfors (Munk / MunkDev)
-- Website: https://github.com/seblindfors
-- Licence: GPL version 2 (General Public License)
--
---------------------------------------------------------------
-- Interface node calculations and management
---------------------------------------------------------------
-- Accessory driver to scan a given interface hierarchy and
-- calculate distances and travel path between nodes, where a
-- node is any object in the hierarchy that is considered to be
-- interactive, either by clicking or mousing over it.
-- Calling NODE(...) with a list of frames will
-- cache all nodes in the hierarchy for later use.
---------------------------------------------------------------
-- API
---------------------------------------------------------------
--  NODE(frame1, frame2, ..., frameN)
--  NODE.ClearCache()
--  NODE.IsDrawn(node, super)
--  NODE.IsRelevant(node)
--  NODE.GetScrollButtons(node)
--  NODE.NavigateToBestCandidate(cur, key)
--  NODE.NavigateToClosestCandidate(cur, key)
--  NODE.NavigateToArbitraryCandidate([cur, old, origX, origY])
---------------------------------------------------------------
-- Node attributes
---------------------------------------------------------------
--  nodeignore       : (boolean) ignore this node
--  nodepriority     : (number)  priority in arbitrary selection
--  nodesingleton    : (boolean) no recursive scan on this node
--  nodepass         : (boolean) include children, skip node
---------------------------------------------------------------
local LibStub = _G.LibStub
local NODE = LibStub:NewLibrary('ConsolePortNode', 1)
if not NODE then return end

-- Eligibility
local IsMouseResponsive
local IsUsable
local IsInteractive
local IsRelevant
local IsTree
local IsDrawn
-- Attachments
local GetSuperNode
local GetScrollButtons
-- Recursive scanner
local Scan
local ScanLocal
local ScrubCache
-- Cache control
local CacheItem
local CacheRect
local Insert
local RemoveCacheItem
local ClearCache
local HasItems
local GetNextCacheItem
local GetFirstEligibleCacheItem
local GetRectLevelIndex
local IterateCache
local IterateRects
-- Rect calculations
local GetHitRectCenter
local GetCenterPos
local GetCenterScaled
local DoNodesIntersect
local GetAbsFrameLevel
local PointInRange
local CanLevelsIntersect
local DoNodeAndRectIntersect
-- Vector calculations
local GetAngleBetween
local GetAngleDistance
local GetDistance
local GetDistanceSum
local IsCloser
local GetCandidateVectorForCurrent
local GetCandidatesForVector
local GetPriorityCandidate
-- Navigation
local GetNavigationKey
local SetNavigationKey
local NavigateToBestCandidate
local NavigateToBestCandidateV2
local NavigateToClosestCandidate
local NavigateToArbitraryCandidate

---------------------------------------------------------------
-- Data handling
---------------------------------------------------------------
-- RECTS  : cache of all interactive rectangles drawn on screen
-- CACHE  : cache of all eligible nodes in order of priority
-- BOUNDS : limit the boundaries of scans/selection to screen
-- SCALAR : scale 2ndary plane to improve intuitive node selection
-- DIVDEG : angle divisor for vector scaling
-- USABLE : what to consider as interactive nodes by default
-- LEVELS : frame level quantifiers (each strata has 10k levels)
---------------------------------------------------------------
local CACHE, RECTS = {}, {};
local BOUNDS = CreateVector3D(GetScreenWidth(), GetScreenHeight(), UIParent:GetEffectiveScale());
local SCALAR = 3;
local DIVDEG = 15;
local USABLE = {
	Button      = true;
	CheckButton = true;
	EditBox     = true;
	Slider      = true;
};
local LEVELS = {
	BACKGROUND        = 00000;
	LOW               = 10000;
	MEDIUM            = 20000;
	HIGH              = 30000;
	DIALOG            = 40000;
	FULLSCREEN        = 50000;
	FULLSCREEN_DIALOG = 60000;
	TOOLTIP           = 70000;
};

---------------------------------------------------------------
-- Main object
---------------------------------------------------------------
local NODE = setmetatable(Mixin(NODE, {
	-- Compares distance between nodes for eligibility when filtering cached nodes
	picky = {
		UP    = function(_, destY, horz, vert, _, thisY) return (vert > horz and destY > thisY) end;
		DOWN  = function(_, destY, horz, vert, _, thisY) return (vert > horz and destY < thisY) end;
		LEFT  = function(destX, _, horz, vert, thisX, _) return (vert < horz and destX < thisX) end;
		RIGHT = function(destX, _, horz, vert, thisX, _) return (vert < horz and destX > thisX) end;
	};
	-- Balances distance and direction for eligibility when filtering cached nodes
	balanced = {
		UP    = function(_, destY, horz, vert, _, thisY) return (vert >= horz and destY > thisY) end;
		DOWN  = function(_, destY, horz, vert, _, thisY) return (vert >= horz and destY < thisY) end;
		LEFT  = function(destX, _, horz, vert, thisX, _) return (vert <= horz and destX < thisX) end;
		RIGHT = function(destX, _, horz, vert, thisX, _) return (vert <= horz and destX > thisX) end;
	};
	-- Compares more generally to catch any nodes located in a given direction
	permissive = {
		UP    = function(_, destY, _, _, _, thisY) return (destY > thisY) end;
		DOWN  = function(_, destY, _, _, _, thisY) return (destY < thisY) end;
		LEFT  = function(destX, _, _, _, thisX, _) return (destX < thisX) end;
		RIGHT = function(destX, _, _, _, thisX, _) return (destX > thisX) end;
	};
	angles = {
		UP    = math.rad(0);
		DOWN  = math.rad(180);
		LEFT  = math.rad(-90);
		RIGHT = math.rad(90);
	};
	keys = {
		PADDUP    = 'UP';    W = 'UP';
		PADDDOWN  = 'DOWN';  S = 'DOWN';
		PADDLEFT  = 'LEFT';  A = 'LEFT';
		PADDRIGHT = 'RIGHT'; D = 'RIGHT';
	};
}), {
	-- @param  varargs : list of frames to scan recursively
	-- @return cache   : table of nodes on screen
	__call = function(self, ...)
		ClearCache()
		Scan(nil, ...)
		ScrubCache(GetNextCacheItem(nil))
		return CACHE
	end;
})

---------------------------------------------------------------
-- Events (update boundaries)
---------------------------------------------------------------
do local function UIScaleChanged()
		BOUNDS:SetXYZ(GetScreenWidth(), GetScreenHeight(), UIParent:GetEffectiveScale())
	end
	local UIScaleHandler = CreateFrame('Frame')
	UIScaleHandler:RegisterEvent('UI_SCALE_CHANGED')
	UIScaleHandler:RegisterEvent('DISPLAY_SIZE_CHANGED')

	UIScaleHandler:SetScript('OnEvent', UIScaleChanged)
	hooksecurefunc(UIParent, 'SetScale', UIScaleChanged)
	UIParent:HookScript('OnSizeChanged', UIScaleChanged)
end

---------------------------------------------------------------
-- Upvalues
---------------------------------------------------------------
local tinsert, tremove, pairs, ipairs, next, wipe =
	tinsert, tremove, pairs, ipairs, next, wipe;
local vlen, huge, abs, deg, atan2 =
	Vector2D_GetLength, math.huge, math.abs, math.deg, math.atan2;
-- Operate within the frame metatable
setfenv(1, GetFrameMetatable().__index)

---------------------------------------------------------------
-- Eligibility
---------------------------------------------------------------

function IsMouseResponsive(node)
	return ( GetScript(node, 'OnEnter') or GetScript(node, 'OnMouseDown') ) and true
end

function IsUsable(object)
	return USABLE[object]
end

function IsInteractive(node, object)
	return 	not IsObjectType(node, 'ScrollFrame')
			and IsMouseEnabled(node)
			and not GetAttribute(node, 'nodepass')
			and ( IsUsable(object) or IsMouseResponsive(node) )
end

function IsRelevant(node)
	return node and not IsForbidden(node) and not GetAttribute(node, 'nodeignore') and IsVisible(node)
end

function IsTree(node)
	return not GetAttribute(node, 'nodesingleton')
end

function IsDrawn(node, super)
	local nX, nY = GetCenterScaled(node)
	local mX, mY = BOUNDS:GetXYZ()
	if ( PointInRange(nX, 0, mX) and PointInRange(nY, 0, mY) ) then
		-- assert node isn't clipped inside a scroll child
		if super and not IsObjectType(node, 'Slider') then
			return DoNodesIntersect(node, super)
		else
			return true
		end
	end
end

---------------------------------------------------------------
-- Attachments
---------------------------------------------------------------
function GetSuperNode(super, node)
	return (IsObjectType(node, 'ScrollFrame')
		or DoesClipChildren(node)) and node
		or super
end

function GetScrollButtons(node)
	if node then
		if IsMouseWheelEnabled(node) then
			for _, frame in pairs({GetChildren(node)}) do
				if IsObjectType(frame, 'Slider') then
					return GetChildren(frame)
				end
			end
		elseif IsObjectType(node, 'Slider') then
			return GetChildren(node)
		else
			return GetScrollButtons(GetParent(node))
		end
	end
end

---------------------------------------------------------------
-- Recursive scanner
---------------------------------------------------------------
function Scan(super, node, sibling, ...)
	if IsRelevant(node) then
		local object, level = GetObjectType(node), GetAbsFrameLevel(node)
		if IsDrawn(node, super) then
			if IsInteractive(node, object) then
				CacheItem(node, object, super, level)
			elseif IsMouseEnabled(node) then
				CacheRect(node, level)
			end
		end
		if IsTree(node) then
			Scan(GetSuperNode(super, node), GetChildren(node))
		end
	end
	if sibling then
		Scan(super, sibling, ...)
	end
end

function ScanLocal(node)
	if IsRelevant(node) then
		local parent, super = node
		while parent do
			if GetSuperNode(nil, parent) then
				super = parent
				break
			end
			parent = parent:GetParent()
		end
		ClearCache()
		Scan(super, node)
		local object = GetObjectType(node)
		if IsInteractive(node, object) then
			CacheItem(node, object, super, GetAbsFrameLevel(node))
		end
		ScrubCache(GetNextCacheItem(nil))
	end
	return CACHE
end

function ScrubCache(i, item)
	while item do
		local node, level = item.node, item.level
		for l, rect in IterateRects() do
			if not CanLevelsIntersect(level, rect.level) then
				break
			end
			if DoNodeAndRectIntersect(node, rect.node) then
				i = RemoveCacheItem(i)
				break
			end
		end
		i, item = GetNextCacheItem(i)
	end
end

---------------------------------------------------------------
-- Cache control
---------------------------------------------------------------

function CacheItem(node, object, super, level)
	CacheRect(node, level)
	Insert(CACHE, GetAttribute(node, 'nodepriority'), {
		node   = node;
		object = object;
		super  = super;
		level  = level;
	})
end

function CacheRect(node, level)
	Insert(RECTS, GetRectLevelIndex(level), {
		node  = node;
		level = level;
	})
end

function Insert(t, k, v)
	if k then
		return tinsert(t, k, v)
	end
	t[#t+1] = v
end

function RemoveCacheItem(cacheIndex)
	tremove(CACHE, cacheIndex)
	return cacheIndex - 1
end

function ClearCache()
	wipe(CACHE)
	wipe(RECTS)
end

function HasItems()
	return #CACHE > 0
end

function GetNextCacheItem(i)
	return next(CACHE, i and i > 0 and i or nil)
end

function GetFirstEligibleCacheItem()
	for _, item in IterateCache() do
		local node = item.node
		if IsVisible(node) and IsDrawn(node, item.super) then
			return item
		end
	end
end

function GetRectLevelIndex(level)
	for index, item in IterateRects() do
		if (item.level < level) then
			return index
		end 		
	end
	return #RECTS+1
end

function IterateCache()
	return ipairs(CACHE)
end

function IterateRects()
	return ipairs(RECTS)
end

---------------------------------------------------------------
-- Rect calculations
---------------------------------------------------------------
local function div2(arg, ...)
	if arg then return arg * 0.5, div2(...) end
end
local function nrmlz(node, effScale, cmpScale, func, ...)
	if func then
		return func(node) * (effScale/cmpScale),
			nrmlz(node, effScale, cmpScale, ...)
	end
end
---------------------------------------------------------------

function GetHitRectCenter(node)
	local x, y, w, h = GetRect(node)
	if not x then return end
	local l, r, t, b = div2(GetHitRectInsets(node))
	return (x+l) + div2(w-r), (y+b) + div2(h-t)
end

function GetCenterScaled(node)
	local x, y = GetHitRectCenter(node)
	if not x then return end
	local scale = GetEffectiveScale(node) / BOUNDS.z;
	return x * scale, y * scale
end

function GetCenterPos(node)
	local x, y = GetCenter(node)
	if not x then return end
	local l, b = GetHitRectCenter(node)
	return (l-x), (b-y)
end

function DoNodesIntersect(n1, n2)
	local left1, right1, top1, bottom1 = nrmlz(
		n1, GetEffectiveScale(n1), BOUNDS.z,
		GetLeft, GetRight, GetTop, GetBottom);
	local left2, right2, top2, bottom2 = nrmlz(
		n2, GetEffectiveScale(n2), BOUNDS.z,
		GetLeft, GetRight, GetTop, GetBottom);
	return  (left1   <  right2)
		and (right1  >   left2)
		and (bottom1 <    top2)
		and (top1    > bottom2)
end

function GetAbsFrameLevel(node)
	return LEVELS[GetFrameStrata(node)] + GetFrameLevel(node)
end

function PointInRange(pt, min, max)
	return pt and pt >= min and pt <= max
end

function CanLevelsIntersect(level1, level2)
	return level1 < level2
end

function DoNodeAndRectIntersect(node, rect)
	local x, y = GetCenterScaled(node)
	local scale, limit = GetEffectiveScale(rect), BOUNDS.z;
	return PointInRange(x, nrmlz(rect, scale, limit, GetLeft, GetRight)) and
		   PointInRange(y, nrmlz(rect, scale, limit, GetBottom, GetTop))
end

---------------------------------------------------------------
-- Vector calculations
---------------------------------------------------------------
function GetDistance(x1, y1, x2, y2)
	return abs(x1 - x2), abs(y1 - y2)
end

function GetDistanceSum(...)
	local x, y = GetDistance(...)
	return x + y
end

function IsCloser(hz1, vt1, hz2, vt2)
	return vlen(hz1, vt1) < vlen(hz2, vt2)
end

function GetAngleBetween(x1, y1, x2, y2)
	return atan2(x2 - x1, y2 - y1)
end

function GetAngleDistance(a1, a2)
	return (180 - abs(abs(deg(a1) - deg(a2)) - 180));
end

function GetCandidateVectorForCurrent(cur)
	local x, y = GetCenterScaled(cur.node)
	return {x = x; y = y; h = huge; v = huge; a = 0}
end 

function GetCandidatesForVector(vector, comparator, candidates)
	local thisX, thisY = vector.x, vector.y
	for i, destination in IterateCache() do
		local candidate = destination.node
		local destX, destY = GetCenterScaled(candidate)
		local distX, distY = GetDistance(thisX, thisY, destX, destY)

		if comparator(destX, destY, distX, distY, thisX, thisY) then
			candidates[destination] = { 
				x = destX; y = destY; h = distX; v = distY;
				a = GetAngleBetween(thisX, thisY, destX, destY);
			}
		end
	end 
	return candidates
end

---------------------------------------------------------------
-- Navigation
---------------------------------------------------------------
-- @param key       : navigation key
-- @param direction : direction of travel (nil to remove)
function SetNavigationKey(key, direction)
	NODE.keys[key] = direction
end

function GetNavigationKey(key)
	return NODE.keys[key] or key;
end

---------------------------------------------------------------
-- Get the best candidate to a given origin and direction
---------------------------------------------------------------
-- This method uses vectors over manhattan distance, stretching 
-- from an origin node to new candidate nodes, using direction.
-- The vectors are artificially inflated in the secondary plane
-- to the travel direction (X for up/down, Y for left/right),
-- prioritizing candidates more linearly aligned to the origin.
-- Comparing Euclidean distance on vectors yields the best node.

function NavigateToBestCandidate(cur, key, curNodeChanged) key = GetNavigationKey(key)
	if cur and NODE.picky[key] then
		local this = GetCandidateVectorForCurrent(cur)
		local candidates = GetCandidatesForVector(this, NODE.picky[key], {})

		local hMult = (key == 'UP' or key == 'DOWN') and SCALAR or 1
		local vMult = (key == 'LEFT' or key == 'RIGHT') and SCALAR or 1

		for candidate, vector in pairs(candidates) do
			if IsCloser(vector.h * hMult, vector.v * vMult, this.h, this.v) then
				this, cur, curNodeChanged = vector, candidate, curNodeChanged;
				this.h, this.v = (this.h * hMult), (this.v * vMult);
			end
		end
		return cur, curNodeChanged;
	end
end

---------------------------------------------------------------
-- Get the best candidate to a given origin and direction (v2)
---------------------------------------------------------------
-- This method uses vectors and angles to prioritize candidates
-- that are closer to the optimal direction of travel, using
-- the angle between the origin and the destination as another
-- metric for comparison. The difference from V1 is that this
-- method has a dynamic scaling factor for the vectors, making
-- it more accurate when the travel direction is diagonal.

function NavigateToBestCandidateV2(cur, key, curNodeChanged) key = GetNavigationKey(key)
	if cur and NODE.balanced[key] then
		local this = GetCandidateVectorForCurrent(cur)
		local optimalAngle = NODE.angles[key];
		local candidates = GetCandidatesForVector(this, NODE.balanced[key], {})

		for candidate, vector in pairs(candidates) do
			local offset = GetAngleDistance(optimalAngle, vector.a)
			local weight = 1 + (offset / DIVDEG)
			if IsCloser(vector.h * weight, vector.v * weight, this.h, this.v) then
				this, cur, curNodeChanged = vector, candidate, true;
				this.h, this.v = (this.h * weight), (this.v * weight);
			end
		end
		return cur, curNodeChanged;
	end
end

---------------------------------------------------------------
-- Set the closest candidate to a given origin
---------------------------------------------------------------
-- Used as a fallback method when a proper candidate can't be
-- located using both direction and distance-based vectors,
-- instead using only shortest path as the metric for movement.

function NavigateToClosestCandidate(cur, key, curNodeChanged) key = GetNavigationKey(key)
	if cur and NODE.permissive[key] then
		local this = GetCandidateVectorForCurrent(cur)
		local candidates = GetCandidatesForVector(this, NODE.permissive[key], {})

		for candidate, vector in pairs(candidates) do
			if IsCloser(vector.h, vector.v, this.h, this.v) then
				this, cur, curNodeChanged = vector, candidate, true;
			end
		end
		return cur, curNodeChanged;
	end
end

---------------------------------------------------------------
-- Get an arbitrary candidate based on priority mapping
---------------------------------------------------------------
function NavigateToArbitraryCandidate(cur, old, x, y)
	-- (1) attempt to return the last node before the cache was wiped
	-- (2) attempt to return the current node if it's still drawn
	-- (3) return the first item in the cache if there are no origin coordinates
	-- (4) return any node that's close to the origin coordinates or has priority
	return 	( cur and IsRelevant(cur.node) and IsDrawn(cur.node) ) and cur or
			( old and IsRelevant(old.node) and IsDrawn(old.node) ) and old or
			( not x or not y ) and GetFirstEligibleCacheItem() or
			( HasItems() ) and GetPriorityCandidate(x, y)
end

function GetPriorityCandidate(x, y, targNode, targDist, targPrio)
	for _, this in IterateCache() do
		local thisDist = GetDistanceSum(x, y, GetCenterScaled(this.node))
		local thisPrio = GetAttribute(this.node, 'nodepriority')

		if thisPrio and not targPrio then
			targNode = this;
			break
		elseif not targNode or ( not targPrio and thisDist < targDist ) then
			targNode, targDist, targPrio = this, thisDist, thisPrio;
		end
	end
	return targNode;
end

---------------------------------------------------------------
-- Interface access
---------------------------------------------------------------
NODE.IsDrawn = IsDrawn;
NODE.ScanLocal = ScanLocal;
NODE.GetCenter = GetCenterScaled;
NODE.GetCenterPos = GetCenterPos;
NODE.GetCenterScaled = GetCenterScaled;
NODE.GetDistance = GetDistance;
NODE.IsRelevant = IsRelevant;
NODE.ClearCache = ClearCache;
NODE.GetScrollButtons = GetScrollButtons;
NODE.GetNavigationKey = GetNavigationKey;
NODE.SetNavigationKey = SetNavigationKey;
NODE.NavigateToBestCandidate = NavigateToBestCandidate;
NODE.NavigateToBestCandidateV2 = NavigateToBestCandidateV2;
NODE.NavigateToClosestCandidate = NavigateToClosestCandidate;
NODE.NavigateToArbitraryCandidate = NavigateToArbitraryCandidate;

---------------------------------------------------------------
-- Extend Carpenter API
---------------------------------------------------------------
do local Lib = LibStub:GetLibrary('Carpenter')
	if not Lib then return end
	Lib:ExtendAPI('IgnoreNode', function(self, ...) self:SetAttribute('nodeignore', ...) end)
	Lib:ExtendAPI('PriorityNode', function(self, ...) self:SetAttribute('nodepriority', ...) end)
	Lib:ExtendAPI('SingletonNode', function(self, ...) self:SetAttribute('nodesingleton', ...) end)
end