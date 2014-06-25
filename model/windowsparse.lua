------------------------------------------------------------------------
--[[ WindowSparse ]]--
-- A 3 layer model of Distributed Conditional Computation
------------------------------------------------------------------------
local WindowSparse, parent = torch.class("dp.WindowSparse", "dp.Layer")
WindowSparse.isWindowSparse = true

function WindowSparse:__init(config)
   assert(type(config) == 'table', "Constructor requires key-value arguments")
   local args, input_size, window_size, input_stdv, output_stdv, noise_stdv,
      hidden_size, gater_size, output_size, lr, norm_period, 
      sparse_init, typename = xlua.unpack(
      {config},
      'WindowSparse', 
      'Deep mixture of experts model. It is three parametrized '..
      'layers of gated experts. There are two gaters, one for each '..
      'layer of hidden neurons.',
      {arg='input_size', type='number', req=true,
       help='Number of input neurons'},
      {arg='window_size', type='table', req=true,
       help='A table of window sizes. Should be smaller than '..
       'commensurate hidden size.'},
      {arg='input_stdv', type='table', req=true,
       help='stdv of gaussian blur of targets for WindowGate'},
      {arg='output_stdv', type='table', req=true,
       help='stdv of gaussian blur of output of WindowGate'},
      {arg='noise_stdv', type='table', req=true,
       help='stdv of gaussian noise on input of WindowGate'},
      {arg='hidden_size', type='table', req=true,
       help='size of the hidden layers between nn.WindowSparses.'},
      {arg='gater_size', type='table', req=true,
       help='output size of the gaters'},
      {arg='output_size', type='number', req=true,
       help='output size of last layer'},
      {arg='lr', type='table', req=true,
       help='lr of gaussian blur target'},
      {arg='norm_period', type='number', default=5,
       help='Every norm_period batches, maxNorm is called'},
      {arg='sparse_init', type='boolean', default=false,
       help='sparse initialization of weights. See Martens (2010), '..
       '"Deep learning via Hessian-free optimization"'},
      {arg='typename', type='string', default='windowsparse', 
       help='identifies Model type in reports.'}
   )
   self._input_size = input_size
   self._window_size = window_size
   self._output_size = output_size
   self._gater_size = gater_size
   self._hidden_size = hidden_size
   self._input_stdv = input_stdv
   self._output_stdv = output_stdv
   self._noise_stdv = noise_stdv
   self._lr = lr
   self._norm_period = norm_period
   self._norm_iter = 0
   
   require 'nnx'
      
   --[[ First Layer : Input is dense, output is sparse ]]--
   -- Gater A
   local gaterA = nn.Sequential()
   gaterA:add(nn.Linear(self._input_size, self._gater_size[1]))
   gaterA:add(nn.SoftMax())
   local balanceA = nn.Balance(10)
   --gaterA:add(balanceA)
   local gateA = nn.WindowGate(self._window_size[1], self._hidden_size[1], self._input_stdv[1], self._output_stdv[1], self._lr[1], self._noise_stdv[1])
   gaterA:add(gateA)
   
   -- Experts A
   local mlpA = nn.Sequential()
   local expertsA = nn.WindowSparse(self._input_size, self._hidden_size[1], self._window_size[1], true) 
   mlpA:add(expertsA)
   local paraA = nn.ParallelTable()
   paraA:add(nn.Tanh()) -- non-linearity of experts (WindowSparse)
   paraA:add(nn.Identity()) -- forwards indices
   mlpA:add(paraA)
   
   -- Mixture A
   local mixtureA = nn.WindowMixture(mlpA, gaterA, nn.WindowMixture.DENSE_SPARSE)


   --[[ Second Layer : Input and output are sparse ]]--
   -- Gater B : The input to the B gater is sparse so we use a nn.WindowSparse instead of a nn.Linear:
   local gaterB = nn.Sequential()
   gaterB:add(nn.WindowSparse(self._hidden_size[1] ,self._gater_size[2], self._gater_size[2]))
   gaterB:add(nn.ElementTable(1))
   gaterB:add(nn.SoftMax())
   local balanceB = nn.Balance(10)
   --gaterB:add(balanceB)
   local gateB = nn.WindowGate(self._window_size[2], self._hidden_size[2], self._input_stdv[2], self._output_stdv[2], self._lr[2], self._noise_stdv[2])
   gaterB:add(gateB)
   
   -- Experts B
   local mlpB = nn.Sequential()
   -- this is where most of the sparsity-based performance gains are :
   local expertsB = nn.WindowSparse(self._hidden_size[1], self._hidden_size[2], self._window_size[2], true)
   mlpB:add(expertsB)
   local paraB = nn.ParallelTable()
   paraB:add(nn.Tanh()) -- non-linearity of experts (WindowSparse)
   paraB:add(nn.Identity())
   mlpB:add(paraB)
   
   -- Mixture B
   local mixtureB = nn.WindowMixture(mlpB, gaterB, nn.WindowMixture.SPARSE_SPARSE)
   

   --[[ Third Layer : Input is sparse, output is dense ]]--
   -- Mixture C
   local mixtureC = nn.Sequential()
   local expertsC = nn.WindowSparse(self._hidden_size[2], self._output_size, self._output_size, true)
   mixtureC:add(expertsC)
   mixtureC:add(nn.ElementTable(1))
   mixtureC:add(nn.Tanh())

   --[[ Stack Mixtures ]]--
   -- Stack the 3 mixtures of experts layers. 
   local mlp = nn.Sequential()
   mlp:add(mixtureA)
   mlp:add(mixtureB)
   mlp:add(mixtureC)
   mlp:zeroGradParameters()
   
   self._gaterA = gaterA
   self._gaterB = gaterB
   self._gateA = gateA
   self._gateB = gateB
   self._balanceA = balanceA
   self._balanceB = balanceB
   self._expertsA = expertsA
   self._expertsB = expertsB
   self._expertsC = expertsC
   self._mixtureA = mixtureA
   self._mixtureB = mixtureB
   self._mixtureC = mixtureC
   self._module = mlp
   
   config.typename = typename
   config.output = dp.DataView()
   config.input_view = 'bf'
   config.output_view = 'bf'
   config.tags = config.tags or {}
   config.tags['no-momentum'] = true
   config.sparse_init = sparse_init
   parent.__init(self, config)
   -- only works with cuda
   self:type('torch.CudaTensor')
end

-- requires targets be in carry
function WindowSparse:_forward(carry)
   local input = self:inputAct()
   self._gateA.train = true
   self._gateB.train = true
   self._balanceA.train = true
   self._balanceB.train = true
   local outputAct = self._module:forward(input)
   self:outputAct(outputAct)
   -- statistics
   local centroidA = self._gateA.normalizedCentroid
   local centroidB = self._gateB.normalizedCentroid
   self._stats.stdA = 0.9*self._stats.stdA + 0.1*centroidA:std()
   self._stats.stdB = 0.9*self._stats.stdB + 0.1*centroidB:std()
   self._stats.meanA = 0.9*self._stats.meanA + 0.1*centroidA:mean()
   self._stats.meanB = 0.9*self._stats.meanB + 0.1*centroidB:mean()
   return carry
end

-- requires targets be in carry
function WindowSparse:_evaluate(carry)
   local input = self:inputAct()
   self._gateA.train = false
   self._gateB.train = false
   self._balanceA.train = false
   self._balanceB.train = false
   local outputAct = self._module:forward(input)
   -- statistics
   local tgtA = self._gateA.targetCentroid
   local tgtB = self._gateB.targetCentroid
   self._stats.tgtStdA = 0.9*self._stats.tgtStdA + 0.1*tgtA:std()
   self._stats.tgtStdB = 0.9*self._stats.tgtStdB + 0.1*tgtB:std()
   self._stats.tgtMeanA = 0.9*self._stats.tgtMeanA + 0.1*tgtA:mean()
   self._stats.tgtMeanB = 0.9*self._stats.tgtMeanB + 0.1*tgtB:mean()
   self:outputAct(outputAct)
   return carry
end

function WindowSparse:_backward(carry)
   self._acc_scale = carry.scale or 1
   self._report.scale = self._acc_scale
   local input_act = self:inputAct()
   local output_grad = self:outputGrad()
   -- we don't accGradParameters as updateParameters will do so inplace
   output_grad = self._module:updateGradInput(input_act, output_grad)
   self._stats.errorA = 0.9*self._stats.errorA + 0.1*self._gateA.error:mean()
   self._stats.errorB = 0.9*self._stats.errorB + 0.1*self._gateB.error:mean()
   self:inputGrad(output_grad)
   return carry
end

function WindowSparse:paramModule()
   return self._module
end

function WindowSparse:_type(type)
   self._input_type = type
   self._output_type = type
   self._module:type(type)
   return self
end

function WindowSparse:reset()
   self._module:reset()
   if self._sparse_init then
      self._sparseReset(self._module.weight)
   end
end

function WindowSparse:zeroGradParameters()
   --self._module:zeroGradParameters(true)
end

-- if after feedforward, returns active parameters 
-- else returns all parameters
function WindowSparse:parameters()
   return self._module:parameters()
end

function WindowSparse:sharedClone()
   error"Not Implemented"
end

function WindowSparse:updateParameters(lr)
   -- we update parameters inplace (much faster)
   -- so don't use this with momentum (disabled by default)
   self._module:accUpdateGradParameters(self:inputAct(), self:outputGrad(), self._acc_scale * lr)
   --self._gaterA:get(1).bias:zero()
   --self._gaterB:get(1).bias:zero()
   return
end

-- Only affects 2D parameters.
-- Assumes that 2D parameters are arranged (output_dim x input_dim)
function WindowSparse:maxNorm(max_out_norm, max_in_norm)
   self._norm_iter = self._norm_iter + 1
   if self._norm_iter == self._norm_period then
      assert(self.backwarded, "Should call maxNorm after a backward pass")
      max_out_norm = self.mvstate.max_out_norm or max_out_norm
      max_in_norm = self.mvstate.max_in_norm or max_in_norm
      local params, gradParams = self:parameters()
      for k,param in pairs(params) do
         if param:dim() == 2 then
            if max_out_norm then
               -- rows feed into output neurons 
               param:renorm(1, 2, max_out_norm)
            end
            if max_in_norm then
               -- cols feed out from input neurons
               param:renorm(2, 2, max_out_norm)
            end
         end
      end
      self._norm_iter = 0
   end
end

function WindowSparse:_zeroStatistics()
   self._stats.errorA = 0
   self._stats.errorB = 0
   self._stats.stdA = 0
   self._stats.stdB = 0
   self._stats.meanA = 0
   self._stats.meanB = 0
   self._stats.tgtStdA = 0
   self._stats.tgtStdB = 0
   self._stats.tgtMeanA = 0
   self._stats.tgtMeanB = 0
end

function WindowSparse:report()
   print(self:name())
   print("gaterA", self._stats.errorA, self._stats.meanA, "+-", self._stats.stdA, self._stats.tgtMeanA, "+-", self._stats.tgtStdA)
   print("gaterB", self._stats.errorB, self._stats.meanB, "+-", self._stats.stdB, self._stats.tgtMeanB, "+-", self._stats.tgtStdB)
end
