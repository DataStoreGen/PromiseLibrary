local Promise = {}
Promise.__index = Promise
local HttpService = game:GetService('HttpService')

local pending, fulfilled, rejected = 'PENDING', 'FULFILLED', 'REJECTED'

function Promise.new(executor)
	assert(type(executor) == 'function', 'Executor must be a function')
	local self = {
		_state = pending,
		_value = nil,
		_callbacks = {}
	}
	setmetatable(self, Promise)
	
	local function resolve(value)
		if self._state ~= pending then return end
		self._state = fulfilled
		self._value = value
		self:_flushCallbacks()
	end
	
	local function reject(reason)
		if self._state ~= pending then return end
		self._state = rejected
		self._value = reason
		self:_flushCallbacks()
	end
	local ok, err = pcall(executor, resolve, reject)
	if not ok then
		reject(err)
	end
	return self
end

function Promise.LogMessage(level: string, message: string)
	return Promise.new(function(resolve, reject)
		if type(level) ~= 'string' or type(message) ~= 'string' then
			reject(`Invaild args: 'level' and 'message' must be a string type`)
			return
		end
		local logLevels = {
			Debug = true,
			Info = true,
			Warn = true,
			Error = true,
		}
		if not logLevels[level] then
			reject(string.format('Invalid log level: %s', level))
			return
		end
		local levelMessage = string.format('[PromiseModule] [%s] %s', level, message)
		if level == 'Error' then
			reject(levelMessage)
			error(levelMessage)
		elseif level == 'Warn' then
			warn(levelMessage)
		else
			print(levelMessage)
		end
		resolve(levelMessage)
	end)
end

function Promise:_flushCallbacks()
	for _, callBack in ipairs(self._callbacks) do
		local success, result = pcall(callBack[self._state], self._value)
		if not success then
			callBack.reject(result)
		else
			callBack.resolve(result)
		end
	end
	self._callbacks = nil
end

function Promise:Then(onFulfilled, onRejected)
	local parent = self
	return Promise.new(function(resolve, reject)
		local function handleCallback()
			if parent._state == fulfilled then
				local success, result = pcall(onFulfilled or function(v) return v end, parent._value)
				if success then resolve(result) else reject(result) end
			elseif parent._state == rejected then
				local success, result = pcall(onRejected or function(e) error(e) end, parent._value)
				if success then resolve(result) else reject(result) end
			else
				table.insert(parent._callbacks, {
					[fulfilled] = function(value)
						local success, result = pcall(onFulfilled or function(v) return v end, value)
						if success then resolve(result) else reject(result) end
					end,
					[rejected] = function(reason)
						local success, result = pcall(onRejected or function(e) error(e) end, reason)
						if success then resolve(result) else reject(result) end
					end,
					resolve = resolve,
					reject = reject,
				})
			end
		end
		handleCallback()
	end)
end

function Promise:catch(onRejected)
	return self:Then(nil, onRejected)
end

function Promise:finally(onFinally)
	return self:Then(
		function(value)
			if onFinally then onFinally() end
			return value
		end,
		function(reason)
			if onFinally then onFinally() end
			error(reason)
		end
	)
end

function Promise.resolve(value)
	return Promise.new(function(resolve) resolve(value) end)
end

function Promise.all(promises)
	return Promise.new(function(resolve, reject)
		local results = {}
		local count = 0
		local total = #promises
		for i, promise in ipairs(promises) do
			promise:Then(
				function(value)
					results[i] = value
					count = count + 1
					if count == total then
						resolve(results)
					end
				end,
				reject
			)
		end
		if total == 0 then
			resolve(results)
		end
	end)
end

function Promise:Error(onError: (reason: any) -> any?)
	return self:Then(nil, function(reason: any)
		local success, result = pcall(onError, reason)
		if not success then error(result) end
		return result
	end)
end

function Promise.retry(executor: (resolve: (any) -> (), reject: (any) -> ()) -> (), retries: number)
	return Promise.new(function(resolve, reject)
		local function attempt(remaining)
			Promise.new(executor)
				:Then(resolve)
				:catch(function(err)
					if remaining > 0 then
						attempt(remaining - 1)
					else
						reject(err)
					end
				end)
		end
		attempt(retries)
	end)
end

function Promise.delay(seconds: number)
	return Promise.new(function(resolve)
		task.delay(seconds, function()
			resolve()
		end)
	end)
end

function Promise.timeOut(promise, seconds: number)
	return Promise.new(function(resolve, reject)
		local timeOut = false
		task.delay(seconds, function()
			timeOut = true
			reject('Promise timed out')
		end)
		promise:Then(function(value)
			if not timeOut then resolve(value) end
		end, function(reason)
			if not timeOut then reject(reason) end
		end)
	end)
end

function Promise.resume(thread: thread)
	return Promise.new(function(resolve, reject)
		local success, result = coroutine.resume(thread)
		if not success then reject(result) else resolve(result) end
	end)
end

function Promise.wrap(func: (...any) -> any)
	return function<T...>(...: T...)
		local args = {...}
		return Promise.new(function(resolve, reject)
			local success, result = pcall(func, table.unpack(args))
			if success then
				resolve(result)
			else
				reject(result)
			end
		end)
	end
end

function Promise.retryDelay(executor, retries: number, delaySeconds: number)
	return Promise.new(function(resolve, reject)
		local function attempt(remainingRetries)
			Promise.new(executor)
				:Then(resolve)
				:catch(function(err)
					if remainingRetries > 0 then
						Promise.delay(delaySeconds):Then(function()
							attempt(remainingRetries - 1)
						end)
					else
						reject(err)
					end
				end)
		end
		attempt(retries)
	end)
end

function Promise.filter(promises, filterFunc: (any) -> boolean)
	return Promise.new(function(resolve, reject)
		Promise.all(promises):Then(function(result)
			local filtered = {}
			for _, value in ipairs(result) do
				if filterFunc(value) then
					table.insert(filtered, value)
				end
			end
			resolve(filtered)
		end, reject)
	end)
end

function Promise.try(func: () -> any)
	return Promise.new(function(resolve, reject)
		local success, result = pcall(func)
		if success then resolve(func) else reject(result) end
	end)
end

local eventListen = {}
local asyncQueue = {}
local queueMutex = false

function Promise.retryAsync(executor, retries: number, delaySeconds: number)
	return Promise.new(function(resolve, reject)
		retries = retries or 30
		delaySeconds = delaySeconds or 0.3
		local function attempt(remainingRetries: number)
			Promise.new(executor):Then(function(result)
				resolve(result)
			end):catch(function(err)
				if remainingRetries > 0 then
					Promise.delay(delaySeconds):Then(function()
						attempt(remainingRetries - 1)
					end)
				else
					reject(err)
				end
			end)
		end
		attempt(retries)
	end)
end

function Promise.ProccessAsync()
	return Promise.new(function(resolve, reject)
		local function processQueue()
			while true do
				if #asyncQueue > 0 then
					local func
					while queueMutex do task.wait(0.01) end
					queueMutex = true
					func = table.remove(asyncQueue, 1)
					queueMutex = false

					local success, err = pcall(func)
					if not success then
						Promise.LogMessage('Error', string.format("Queuing process error: %s", err)):catch(reject)
					else
						Promise.LogMessage('Info', "Task processed successfully.")
					end
				end
				task.wait(0.1)
			end
		end
		coroutine.wrap(processQueue)()

		task.wait(0.1)
		if #asyncQueue == 0 then
			resolve("All tasks processed successfully.")
		end
	end)
end

function Promise.repeatUntil(executor, delaySeconds: number)
	return Promise.new(function(resolve, reject)
		local success, result
		repeat
			success, result = pcall(executor)
			if not success then
				print('retrying...')
				task.wait(delaySeconds)
			end
		until success
		resolve(result)
	end)
end

function Promise.race(promises)
	return Promise.new(function(resolve, reject)
		for _, promise in ipairs(promises) do
			promise:Then(function(value)
				resolve(value)
			end, function(reason)
				reject(reason)
			end)
		end
	end)
end

function Promise.fromEvent(singleEvent)
	return Promise.new(function(resolve, reject)
		local connection
		connection = singleEvent:Connect(function(...)
			resolve(...)
			connection:Disconnect()
		end)
	end)
end

function Promise.fromEvents(events)
	return Promise.new(function(resolve, reject)
		local results = {}
		local completed = 0
		local total = #events
		for i, event in ipairs(events) do
			event:Connect(function(...)
				results[i] = {...}
				completed = completed + 1
				if completed == total then
					resolve(results)
				end
			end)
		end
	end)
end

function Promise.print()
	print(Promise)
end

function Promise.CreateEmbed(embed)
	return Promise.new(function(resolve, reject)
		if type(embed) ~= 'table' then
			reject('embed must be a table')
			return
		end
		local title = embed.title
		local description = embed.description
		if title and #title > 256 then
			reject('Embed title cant exceed 256 characters')
			return
		end
		if description and #description > 4086 then
			reject('Embed description cant exceed 4086 characters')
			return
		end
		resolve(embed)
	end)
end

function Promise.sendToDiscord(url: string, data: any, content_type: Enum.HttpContentType?)
	return Promise.new(function(resolve, reject)
		local success, result = pcall(function()
			local jsonData = HttpService:JSONEncode(data)
			return HttpService:PostAsync(url, jsonData, content_type)
		end)
		if success and result then
			resolve(result)
		else
			reject('Failed to send to Discord')
		end
	end)
end

return Promise