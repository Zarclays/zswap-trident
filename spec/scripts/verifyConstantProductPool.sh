# Use this run script to verify the ConstantProductPool.spec
certoraRun spec/harness/ConstantProductPoolHarness.sol spec/harness/SimpleBentoBox.sol spec/harness/Simplifications.sol spec/harness/DummyERC20A.sol spec/harness/DummyERC20B.sol \
	--verify ConstantProductPoolHarness:spec/ConstantProductPool.spec \
	--link ConstantProductPoolHarness:bento=SimpleBentoBox \
	--solc_map ConstantProductPoolHarness=solc8.2,SimpleBentoBox=solc6.12,Simplifications=solc8.2,DummyERC20A=solc8.2,DummyERC20B=solc8.2 \
	--optimistic_loop --loop_iter 2 \
    --packages @openzeppelin=/Users/vasu/Documents/Certora/trident/node_modules/@openzeppelin \
	--staging --msg "ConstantProductPool all rules"