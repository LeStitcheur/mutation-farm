--!strict
-- Limiteur de débit par joueur (seau à jetons). Un limiteur par type de requête.

local Players = game:GetService("Players")

export type RateLimiter = {
	allow: (self: RateLimiter, player: Player) -> boolean,
}

type Bucket = { tokens: number, updatedAt: number }

local RateLimiter = {}

function RateLimiter.new(ratePerSecond: number, burst: number?): RateLimiter
	assert(ratePerSecond > 0, "RateLimiter : débit invalide")
	local capacity = burst or ratePerSecond
	local buckets: { [Player]: Bucket } = {}

	Players.PlayerRemoving:Connect(function(player: Player)
		buckets[player] = nil
	end)

	local function getBucket(player: Player, now: number): Bucket
		local bucket = buckets[player]
		if bucket then
			return bucket
		end
		local created: Bucket = { tokens = capacity, updatedAt = now }
		buckets[player] = created
		return created
	end

	local function allow(_self: RateLimiter, player: Player): boolean
		local now = os.clock()
		local bucket = getBucket(player, now)
		bucket.tokens = math.min(capacity, bucket.tokens + (now - bucket.updatedAt) * ratePerSecond)
		bucket.updatedAt = now
		if bucket.tokens < 1 then
			return false
		end
		bucket.tokens -= 1
		return true
	end

	return { allow = allow }
end

return RateLimiter
