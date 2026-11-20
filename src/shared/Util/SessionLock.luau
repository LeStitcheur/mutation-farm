--!strict
-- SessionLock — règles PURES du verrou de session des profils (docs/ARCHITECTURE.md §7).
-- Utilisées dans les transformations UpdateAsync de DataService ; aucune API Roblox (testées en Lune).
-- Enregistrement stocké : { format, savedAt, data, session = { id, heartbeat } | nil } (horodatages os.time()).

export type AcquireOutcome = "ok" | "locked"

local SessionLock = {}

-- Vrai si `session` est un verrou ACTIF détenu par un autre serveur (heartbeat récent).
function SessionLock.isHeldByOther(session: any, sessionId: string, now: number, timeout: number): boolean
	return type(session) == "table"
		and session.id ~= sessionId
		and type(session.heartbeat) == "number"
		and now - session.heartbeat < timeout
end

-- Acquisition : retourne l'issue, l'enregistrement à écrire (nil = aucune écriture) et la donnée brute lue.
-- Un verrou périmé (serveur planté sans libération) est repris après `timeout` secondes.
function SessionLock.acquire(
	old: any,
	sessionId: string,
	now: number,
	timeout: number,
	format: number
): (AcquireOutcome, any, any)
	local record: any = if type(old) == "table" then old else { format = format, savedAt = 0 }
	if SessionLock.isHeldByOther(record.session, sessionId, now, timeout) then
		return "locked", nil, nil
	end
	record.session = { id = sessionId, heartbeat = now }
	return "ok", record, record.data
end

-- Écriture : nouvel enregistrement, ou nil si le verrou ne nous appartient plus (ne jamais écraser).
-- `release` = sauvegarde finale : le verrou est libéré dans la même écriture.
function SessionLock.write(
	old: any,
	sessionId: string,
	snapshot: any,
	release: boolean,
	now: number,
	format: number
): any
	local session = if type(old) == "table" then old.session else nil
	if type(session) ~= "table" or session.id ~= sessionId then
		return nil
	end
	return {
		format = format,
		data = snapshot,
		session = if release then nil else { id = sessionId, heartbeat = now },
		savedAt = now,
	}
end

-- Libère notre verrou sans modifier la donnée ; nil (aucune écriture) si le verrou n'est pas le nôtre.
function SessionLock.release(old: any, sessionId: string): any
	if type(old) == "table" and type(old.session) == "table" and old.session.id == sessionId then
		old.session = nil
		return old
	end
	return nil
end

return table.freeze(SessionLock)
