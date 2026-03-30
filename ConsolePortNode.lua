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
local NODE = LibStub:NewLibrary('ConsolePortNode', 7)
if not NODE then return end

-- Eligibility
local IsMouseResponsive
local IsUsable
local IsInteractive
local IsRelevant
local IsTree
local IsDrawn
local IsCandidate
-- Attachments
local FindSuperNode
local GetSuperNode
local GetScrollButtons
local CheckClipping
-- Recursive scanner
local Scan
local ScanLocal
local ScrubCache
-- Cache control
local CacheItem
local CacheRect
local Insert
local ClearCache
local HasItems
local GetFirstEligibleCacheItem
local GetRectLevelIndex
local IterateCache
local IterateRects
-- Rect calculations
local GetHitRectScaled
local GetHitRectCenter
local GetCenterPos
local GetCenterScaled
local DoNodesIntersect
local GetAbsFrameLevel
local PointInRange
local CanLevelsIntersect
local GetOffsetPointInfo
-- Vector calculations
local AcquireCandidate
local GetAngleBetween
local GetAngleDistance
local GetDistance
local GetDistanceSum
local IsCloser
local GetCandidateVectorForCurrent
local GetCandidatesForVectorV1
local GetCandidatesForVectorV2
local GetPriorityCandidate
-- Navigation
local GetNavigationKey
local SetNavigationKey
local NavigateToBestCandidateV1
local NavigateToBestCandidateV2
local NavigateToBestCandidateV3
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
-- MDELTA : minimum distance between points in a candidate
-- USABLE : what to consider as interactive nodes by default
-- LEVELS : frame level quantifiers (each strata has 10k levels)
---------------------------------------------------------------
local CACHE, RECTS = {}, {};
local POOL, POOL_N = setmetatable({}, {__mode = 'v'}), 0;
local THIS_VECTOR = {x = 0; y = 0; h = math.huge; v = math.huge; a = 0; o = nil};
local BOUNDS = CreateVector3D(GetScreenWidth(), GetScreenHeight(), UIParent:GetEffectiveScale());
local DEBUG  = false;
local SCALAR = 3;
local DIVDEG = 15;
local MDELTA = 24;
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
	__call = function(_, ...)
		ClearCache()
		Scan(nil, ...)
		ScrubCache()
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
local issecret, scrubsecret =
	issecretvalue or nop, scrubsecretvalues or function(...)return...end;
local select, tinsert, tremove, pairs, ipairs, next, wipe =
	select, tinsert, tremove, pairs, ipairs, next, wipe;
local huge, abs, deg, atan2, max, ceil, floor =
	math.huge, math.abs, math.deg, math.atan2, math.max, math.ceil, math.floor;

if DEBUG then
	DEBUG = Mixin(CreateFrame('Frame', nil, UIParent), ColorMixin)
	DEBUG:SetAllPoints() DEBUG:SetFrameStrata('TOOLTIP')
	DEBUG:SetRGBA(RED_FONT_COLOR, GREEN_FONT_COLOR, BLUE_FONT_COLOR, YELLOW_FONT_COLOR)
	DEBUG.pool = CreateTexturePool(DEBUG, 'OVERLAY', 7)
	DEBUG.draw = function(self, x, y, c)
		local square, new = self.pool:Acquire()
		if new then square:SetSize(4, 4) end
		square:SetPoint('BOTTOMLEFT', UIParent, 'BOTTOMLEFT', x, y)
		square:SetColorTexture(c:GetRGB())
		square:Show()
	end;
	NODE.Info = function(node) return {
		IsCandidate       = IsCandidate(node);
		IsDrawn           = IsDrawn(node, FindSuperNode(node));
		IsInteractive     = IsInteractive(node, node:GetObjectType());
		IsMouseResponsive = IsMouseResponsive(node);
		IsRelevant        = IsRelevant(node);
		IsTree            = IsTree(node);
		IsUsable          = IsUsable(node:GetObjectType());
		ObjectType        = node:GetObjectType();
		DebugName         = node:GetDebugName();
		SuperName         = FindSuperNode(node) and FindSuperNode(node):GetDebugName();
	} end _G.NODE = NODE; -- for debugging
end

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
	return node
		and not IsForbidden(node)
		and scrubsecret(IsVisible(node))
		and not IsAnchoringRestricted(node)
		and not scrubsecret(GetAttribute(node, 'nodeignore'))
		and scrubsecret(GetFrameStrata(node))
		and scrubsecret(GetFrameLevel(node))
		and true
end

function IsTree(node)
	return not GetAttribute(node, 'nodesingleton')
end

function IsDrawn(node, super)
	local nX, nY = GetCenterScaled(node)
	local mX, mY = BOUNDS:GetXYZ()
	if ( PointInRange(nX, 0, mX) and PointInRange(nY, 0, mY) ) then
		-- assert node isn't clipped inside a scroll child
		if super then
			return CheckClipping(node, super)
		else
			return true
		end
	end
end

function IsCandidate(node)
	return  IsRelevant(node)
		and IsDrawn(node)
		and IsInteractive(node, GetObjectType(node))
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

function FindSuperNode(node)
	local parent, super = node
	while parent do
		if GetSuperNode(nil, parent) then
			super = parent
			break
		end
		parent = parent:GetParent()
	end
	return super
end

function CheckClipping(node, super)
	if IsObjectType(super, 'ScrollFrame') then
		local parent, child = super:GetScrollChild(), GetParent(node)
		while child do
			if child == super then
				return true
			end
			if child == parent then
				return DoNodesIntersect(node, super)
			end
			child = child:GetParent()
		end
		return true
	end
	return DoNodesIntersect(node, super)
end

---------------------------------------------------------------
-- Recursive scanner
---------------------------------------------------------------
function Scan(super, ...)
	for i = 1, select('#', ...) do
		local node = select(i, ...)
		if IsRelevant(node) then
			if IsDrawn(node, super) then
				local object, level = GetObjectType(node), GetAbsFrameLevel(node)
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
	end
end

function ScanLocal(node)
	if IsRelevant(node) then
		local super = FindSuperNode(node)
		ClearCache()
		Scan(super, node)
		local object = GetObjectType(node)
		if IsInteractive(node, object) then
			CacheItem(node, object, super, GetAbsFrameLevel(node))
		end
		ScrubCache()
	end
	return CACHE
end

function ScrubCache()
	for i = #CACHE, 1, -1 do
		local item = CACHE[i]
		local cx, cy, level = item.cx, item.cy, item.level
		for _, rect in IterateRects() do
			if not CanLevelsIntersect(level, rect.level) then
				break
			end
			if cx and PointInRange(cx, rect.left, rect.right)
				and PointInRange(cy, rect.bottom, rect.top) then
				tremove(CACHE, i)
				break
			end
		end
	end
end

---------------------------------------------------------------
-- Cache control
---------------------------------------------------------------

function CacheItem(node, object, super, level)
	CacheRect(node, level)
	local cx, cy = GetCenterScaled(node)
	local rx, ry, rw, rh = GetHitRectScaled(node)
	Insert(CACHE, GetAttribute(node, 'nodepriority'), {
		node   = node;
		object = object;
		super  = super;
		level  = level;
		cx     = cx;
		cy     = cy;
		rx     = rx;
		ry     = ry;
		rw     = rw;
		rh     = rh;
	})
end

function CacheRect(node, level)
	local s = GetEffectiveScale(node) / BOUNDS.z;
	Insert(RECTS, GetRectLevelIndex(level), {
		node   = node;
		level  = level;
		left   = GetLeft(node) * s;
		right  = GetRight(node) * s;
		bottom = GetBottom(node) * s;
		top    = GetTop(node) * s;
	})
end

function Insert(t, k, v)
	if k then
		return tinsert(t, k, v)
	end
	t[#t+1] = v
end

function ClearCache()
	wipe(CACHE)
	wipe(RECTS)
	POOL_N = 0;
end

function HasItems()
	return #CACHE > 0
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
	local lo, hi = 1, #RECTS
	while lo <= hi do
		local mid = lo + floor((hi - lo)*.5)
		if RECTS[mid].level < level
		then hi = mid - 1
		else lo = mid + 1
		end
	end
	return lo
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

function GetHitRectCenter(node)
	local x, y, w, h = GetRect(node)
	if issecret(x) or not x then return end
	local l, r, t, b = GetHitRectInsets(node)
	l, r, t, b = l*.5, r*.5, t*.5, b*.5
	return (x+l) + (w-r)*.5, (y+b) + (h-t)*.5
end

function GetHitRectScaled(node)
	local x, y, w, h = GetRect(node)
	if issecret(x) or not x then return end
	local l, r, t, b = GetHitRectInsets(node)
	local s = GetEffectiveScale(node) / BOUNDS.z;
	return (x+l) * s, (y+b) * s, (w-r) * s, (h-t) * s;
end

function GetCenterScaled(node)
	local x, y = GetHitRectCenter(node)
	if issecret(x) or not x then return end
	local scale = GetEffectiveScale(node) / BOUNDS.z;
	return x * scale, y * scale
end

function GetCenterPos(node)
	local x, y = GetCenter(node)
	if issecret(x) or not x then return end
	local l, b = GetHitRectCenter(node)
	return (l-x), (b-y)
end

function DoNodesIntersect(n1, n2)
	local s1 = GetEffectiveScale(n1) / BOUNDS.z
	local s2 = GetEffectiveScale(n2) / BOUNDS.z
	return  (GetLeft(n1)*s1   <  GetRight(n2)*s2)
		and (GetRight(n1)*s1  >   GetLeft(n2)*s2)
		and (GetBottom(n1)*s1 <    GetTop(n2)*s2)
		and (GetTop(n1)*s1    > GetBottom(n2)*s2)
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

function GetOffsetPointInfo(w, h)
	local aspectRatio = max(w / h, h / w)
	if aspectRatio >= 2 then -- > 2:1 valid for extra points
		local isWide = w > h;
		local length = isWide and w or h;
		local points = ceil(aspectRatio*.5) * 2 - 1; -- odd
		local delta  = max(length / points, MDELTA);
		local offset = delta*.5;
		points = max(ceil(length / delta), 1);
		return points, delta, offset, isWide;
	else
		return 1, w, w*.5, true; -- single point
	end
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
	return (hz1*hz1 + vt1*vt1) < (hz2*hz2 + vt2*vt2)
end

function GetAngleBetween(x1, y1, x2, y2)
	return atan2(x2 - x1, y2 - y1)
end

function GetAngleDistance(a1, a2)
	return (180 - abs(abs(deg(a1) - deg(a2)) - 180));
end

function AcquireCandidate(x, y, h, v, a, o)
	POOL_N = POOL_N + 1;
	local c = POOL[POOL_N];
	if not c then
		c = {};
		POOL[POOL_N] = c;
	end
	c.x, c.y, c.h, c.v, c.a, c.o = x, y, h, v, a, o;
	return c;
end

function GetCandidateVectorForCurrent(cur)
	THIS_VECTOR.x, THIS_VECTOR.y = cur.cx, cur.cy;
	THIS_VECTOR.h, THIS_VECTOR.v = huge, huge;
	THIS_VECTOR.a, THIS_VECTOR.o = 0, cur;
	return THIS_VECTOR;
end

function GetCandidatesForVectorV1(vector, comparator, candidates)
	local thisX, thisY = vector.x, vector.y
	for _, destination in IterateCache() do
		local destX, destY = destination.cx, destination.cy
		local distX, distY = GetDistance(thisX, thisY, destX, destY)

		if comparator(destX, destY, distX, distY, thisX, thisY) then
			candidates[destination] = AcquireCandidate(
				destX, destY, distX, distY,
				GetAngleBetween(thisX, thisY, destX, destY),
				destination
			)
		end
	end
	return candidates
end

function GetCandidatesForVectorV2(vector, comparator, candidates)
	local thisX, thisY, cur = vector.x, vector.y, vector.o;

	local x, y, w, h = cur.rx, cur.ry, cur.rw, cur.rh;
	local points, delta, offset, isWide = GetOffsetPointInfo(w, h)
	local destX, destY, distX, distY;

	for i = 1, points do
		destX = isWide and x + (i * delta) - offset or x + w*.5;
		destY = isWide and y + h*.5 or y + (i * delta) - offset;
		distX, distY = GetDistance(thisX, thisY, destX, destY)
		if comparator(destX, destY, distX, distY, thisX, thisY) then
			thisX, thisY = destX, destY;
		end
	end

	for _, destination in IterateCache() do
		if cur ~= destination then
			x, y, w, h = destination.rx, destination.ry, destination.rw, destination.rh;
			destX, destY = x + w*.5, y + h*.5; -- center
			distX, distY = GetDistance(thisX, thisY, destX, destY)

			if comparator(destX, destY, distX, distY, thisX, thisY) then
				points, delta, offset, isWide = GetOffsetPointInfo(w, h)
				for i = 1, points do
					destX = isWide and x + (i * delta) - offset or destX;
					destY = isWide and destY or y + (i * delta) - offset;
					distX, distY = GetDistance(thisX, thisY, destX, destY)
					tinsert(candidates, AcquireCandidate(
						destX, destY, distX, distY,
						GetAngleBetween(thisX, thisY, destX, destY),
						destination
					))
				end
			end
		end
	end

	return candidates;
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

function NavigateToBestCandidateV1(cur, key, curNodeChanged) key = GetNavigationKey(key)
	if cur and NODE.picky[key] then
		local this = GetCandidateVectorForCurrent(cur)
		local candidates = GetCandidatesForVectorV1(this, NODE.picky[key], {})

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
		local candidates = GetCandidatesForVectorV1(this, NODE.balanced[key], {})

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
-- V3: V2 with multiple points per candidate
---------------------------------------------------------------
-- This method is similar to V2, but it uses multiple points
-- per every candidate with extreme aspect ratios, which
-- allows for more accurate selection of candidates that are
-- located in a given direction, even if they are not aligned
-- with the origin node. The candidates are still compared
-- using the angle between the origin and the endpoint.

function NavigateToBestCandidateV3(cur, key, curNodeChanged) key = GetNavigationKey(key)
	if not cur then return end;
	local algorithm, optimalAngle = NODE.permissive[key], NODE.angles[key];
	if not algorithm then return end;

	local this = GetCandidateVectorForCurrent(cur)
	local candidates = GetCandidatesForVectorV2(this, algorithm, {})

	for _, candidate in ipairs(candidates) do
		local offset = GetAngleDistance(optimalAngle, candidate.a)
		local weight = 1 + (offset / DIVDEG)
		if IsCloser(candidate.h * weight, candidate.v * weight, this.h, this.v) then
			this, curNodeChanged = candidate, true;
			this.h, this.v = (this.h * weight), (this.v * weight);
		end
	end
	return this.o, curNodeChanged;
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
		local candidates = GetCandidatesForVectorV1(this, NODE.permissive[key], {})

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
	return 	( cur and IsCandidate(cur.node) ) and cur or
			( old and IsCandidate(old.node) ) and old or
			( not x or not y ) and GetFirstEligibleCacheItem() or
			( HasItems() ) and GetPriorityCandidate(x, y)
end

function GetPriorityCandidate(x, y, targNode, targDist, targPrio)
	for _, this in IterateCache() do
		local thisDist = GetDistanceSum(x, y, this.cx, this.cy)
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
-- Debugging
---------------------------------------------------------------
if DEBUG then
	local _ClearCache = ClearCache;
	function ClearCache(...)
		DEBUG.pool:ReleaseAll()
		return _ClearCache(...)
	end

	local _GetCandidatesForVectorV1 = GetCandidatesForVectorV1;
	function GetCandidatesForVectorV1(...)
		local candidates = _GetCandidatesForVectorV1(...)
		for _, vector in pairs(candidates) do
			DEBUG:draw(vector.x, vector.y, DEBUG.g)
		end
		return candidates;
	end
	local _GetCandidatesForVectorV2 = GetCandidatesForVectorV2;

	function GetCandidatesForVectorV2(...)
		local candidates = _GetCandidatesForVectorV2(...)
		for _, vector in ipairs(candidates) do
			DEBUG:draw(vector.x, vector.y, DEBUG.b)
		end
		return candidates;
	end

	local _NavigateToBestCandidateV2 = NavigateToBestCandidateV2;
	function NavigateToBestCandidateV2(...)
		local cur, curNodeChanged = _NavigateToBestCandidateV2(...)
		if cur then
			local x, y = GetCenterScaled(cur.node)
			DEBUG:draw(x, y, DEBUG.r)
		end
		return cur, curNodeChanged;
	end

	local _NavigateToBestCandidateV3 = NavigateToBestCandidateV3;
	function NavigateToBestCandidateV3(...)
		local cur, curNodeChanged = _NavigateToBestCandidateV3(...)
		if cur then
			local x, y = GetCenterScaled(cur.node)
			DEBUG:draw(x, y, DEBUG.a)
		end
		return cur, curNodeChanged;
	end
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
NODE.NavigateToBestCandidate = NavigateToBestCandidateV1;
NODE.NavigateToBestCandidateV2 = NavigateToBestCandidateV2;
NODE.NavigateToBestCandidateV3 = NavigateToBestCandidateV3;
NODE.NavigateToClosestCandidate = NavigateToClosestCandidate;
NODE.NavigateToArbitraryCandidate = NavigateToArbitraryCandidate;