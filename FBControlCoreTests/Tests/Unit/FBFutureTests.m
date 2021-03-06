/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <XCTest/XCTest.h>

#import <FBControlCore/FBControlCore.h>

@interface FBFutureTests : XCTestCase

@property (nonatomic, strong, readwrite) dispatch_queue_t queue;

@end

@implementation FBFutureTests

- (void)setUp
{
  self.queue = dispatch_queue_create("com.facebook.fbcontrolcore.tests.future", DISPATCH_QUEUE_CONCURRENT);
}

- (void)testResolvesSynchronouslyWithObject
{
  [self assertSynchronousResolutionWithBlock:^(FBMutableFuture *future) {
    [future resolveWithResult:@YES];
  } expectedState:FBFutureStateDone expectedResult:@YES expectedError:nil];
}

- (void)testResolvesAsynchronouslyWithObject
{
  [self waitForAsynchronousResolutionWithBlock:^(FBMutableFuture *future) {
    [future resolveWithResult:@YES];
  } expectedState:FBFutureStateDone expectationKeyPath:@"result" expectationValue:@YES];
}

- (void)testResolvesSynchronouslyWithError
{
  NSError *error = [NSError errorWithDomain:@"foo" code:2 userInfo:nil];
  [self assertSynchronousResolutionWithBlock:^(FBMutableFuture *future) {
    [future resolveWithError:error];
  } expectedState:FBFutureStateFailed expectedResult:nil expectedError:error];
}

- (void)testResolvesAsynchronouslyWithError
{
  NSError *error = [NSError errorWithDomain:@"foo" code:2 userInfo:nil];
  [self waitForAsynchronousResolutionWithBlock:^(FBMutableFuture *future) {
    [future resolveWithError:error];
  } expectedState:FBFutureStateFailed expectationKeyPath:@"error" expectationValue:error];
}

- (void)testEarlyCancellation
{
  [self assertSynchronousResolutionWithBlock:^(FBMutableFuture *future) {
    [future cancel];
  } expectedState:FBFutureStateCancelled expectedResult:nil expectedError:nil];
}

- (void)testAsynchronousCancellation
{
  [self waitForAsynchronousResolutionWithBlock:^(FBMutableFuture *future) {
    [future cancel];
  } expectedState:FBFutureStateCancelled expectationKeyPath:nil expectationValue:nil];
}

- (void)testDiscardsAllResolutionsAfterTheFirst
{
  FBMutableFuture<NSNumber *> *future = FBMutableFuture.future;

  [future resolveWithResult:@YES];

  XCTAssertEqual(future.state, FBFutureStateDone);
  XCTAssertEqual(future.hasCompleted, YES);
  XCTAssertEqual(future.result, @YES);
  XCTAssertEqual(future.error, nil);

  [future resolveWithError:[NSError errorWithDomain:@"foo" code:0 userInfo:nil]];

  XCTAssertEqual(future.state, FBFutureStateDone);
  XCTAssertEqual(future.hasCompleted, YES);
  XCTAssertEqual(future.result, @YES);
  XCTAssertEqual(future.error, nil);
}

- (void)testCallbacks
{
  FBMutableFuture *future = FBMutableFuture.future;
  __block NSUInteger handlerCount = 0;
  [future onQueue:self.queue notifyOfCompletion:^(FBFuture *_) {
    @synchronized (self)
    {
      handlerCount++;
    }
  }];
  [future onQueue:self.queue notifyOfCompletion:^(FBFuture *_) {
    @synchronized (self)
    {
      handlerCount++;
    }
  }];
  [future onQueue:self.queue notifyOfCompletion:^(FBFuture *_) {
    @synchronized (self)
    {
      handlerCount++;
    }
  }];
  dispatch_async(self.queue, ^{
    [future resolveWithResult:@YES];
  });
  NSPredicate *prediate = [NSPredicate predicateWithBlock:^ BOOL (id _, id __) {
    @synchronized (self)
    {
      return handlerCount == 3;
    }
  }];
  XCTestExpectation *expectation = [self expectationForPredicate:prediate evaluatedWithObject:self handler:nil];
  [self waitForExpectations:@[expectation] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
}

- (void)testCompositeSuccess
{
  XCTestExpectation *expectation = [[XCTestExpectation alloc] initWithDescription:@"Composite Callback is called"];

  FBMutableFuture<NSNumber *> *future1 = FBMutableFuture.future;
  FBMutableFuture<NSNumber *> *future2 = FBMutableFuture.future;
  FBMutableFuture<NSNumber *> *future3 = FBMutableFuture.future;
  FBFuture *compositeFuture = [[FBFuture
    futureWithFutures:@[future1, future2, future3]]
    onQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0) notifyOfCompletion:^(FBFuture *future) {
      [expectation fulfill];
    }];

  dispatch_async(self.queue, ^{
    [future1 resolveWithResult:@YES];
  });
  dispatch_async(self.queue, ^{
    [future2 resolveWithResult:@NO];
  });
  dispatch_async(self.queue, ^{
    [future3 resolveWithResult:@10];
  });

  NSArray *expected = @[@YES, @NO, @10];
  [self waitForExpectations:@[expectation] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(compositeFuture.state, FBFutureStateDone);
  XCTAssertEqualObjects(compositeFuture.result, expected);
}

- (void)testCompositeImmediateValue
{
  FBFuture<NSArray<NSNumber *> *> *compositeFuture = [FBFuture futureWithFutures:@[
    [FBFuture futureWithResult:@0],
    [FBFuture futureWithResult:@1],
    [FBFuture futureWithResult:@2],
  ]];

  XCTAssertEqual(compositeFuture.state, FBFutureStateDone);
  XCTAssertEqualObjects(compositeFuture.result, (@[@0, @1, @2]));
}

- (void)testCompositeEmpty
{
  FBFuture<id> *compositeFuture = [FBFuture futureWithFutures:@[]];

  XCTAssertEqual(compositeFuture.state, FBFutureStateDone);
  XCTAssertEqualObjects(compositeFuture.result, (@[]));
}

- (void)testFmappedSuccess
{
  XCTestExpectation *step1 = [[XCTestExpectation alloc] initWithDescription:@"fmap 1 is called"];
  XCTestExpectation *step2 = [[XCTestExpectation alloc] initWithDescription:@"fmap 2 is called"];
  XCTestExpectation *step3 = [[XCTestExpectation alloc] initWithDescription:@"Completion is called"];

  FBMutableFuture<NSNumber *> *baseFuture = FBMutableFuture.future;
  FBFuture<NSNumber *> *chainFuture = [[[baseFuture
    onQueue:self.queue fmap:^(id value) {
      XCTAssertEqualObjects(value, @1);
      [step1 fulfill];
      return [FBFuture futureWithResult:@2];
    }]
    onQueue:self.queue fmap:^(id value) {
      XCTAssertEqualObjects(value, @2);
      [step2 fulfill];
      return [FBFuture futureWithResult:@3];
    }]
    onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
      XCTAssertEqualObjects(future.result, @3);
      [step3 fulfill];
    }];
  dispatch_async(self.queue, ^{
    [baseFuture resolveWithResult:@1];
  });

  [self waitForExpectations:@[step1, step2, step3] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(chainFuture.state, FBFutureStateDone);
  XCTAssertEqualObjects(chainFuture.result, @3);
}

- (void)testTerminateFmapOnError
{
  XCTestExpectation *step1 = [[XCTestExpectation alloc] initWithDescription:@"fmap 1 is called"];
  XCTestExpectation *step2 = [[XCTestExpectation alloc] initWithDescription:@"fmap 2 is called"];
  XCTestExpectation *step3 = [[XCTestExpectation alloc] initWithDescription:@"Completion is called"];
  NSError *error = [NSError errorWithDomain:@"foo" code:2 userInfo:nil];

  FBMutableFuture<NSNumber *> *baseFuture = FBMutableFuture.future;
  FBFuture<NSNumber *> *chainFuture = [[[[baseFuture
    onQueue:self.queue fmap:^(id value) {
      XCTAssertEqualObjects(value, @1);
      [step1 fulfill];
      return [FBFuture futureWithResult:@2];
    }]
    onQueue:self.queue fmap:^(id value) {
      XCTAssertEqualObjects(value, @2);
      [step2 fulfill];
      return [FBFuture futureWithError:error];
    }]
    onQueue:self.queue fmap:^FBFuture *(id _) {
      XCTFail(@"Chained block should not be called after failure");
      return [FBFuture futureWithError:error];
    }]
    onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
      XCTAssertEqualObjects(future.error, error);
      [step3 fulfill];
    }];
  dispatch_async(self.queue, ^{
    [baseFuture resolveWithResult:@1];
  });

  [self waitForExpectations:@[step1, step2, step3] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(chainFuture.state, FBFutureStateFailed);
  XCTAssertEqualObjects(chainFuture.error, error);
}

- (void)testAsyncTimeout
{
  FBMutableFuture<NSNumber *> *future = FBMutableFuture.future;

  NSError *error = nil;
  id value = [future awaitWithTimeout:1 error:&error];
  XCTAssertNil(value);
  XCTAssertNotNil(error);
}

- (void)testAsyncResolution
{
  FBMutableFuture *future = FBMutableFuture.future;
  dispatch_async(self.queue, ^{
    [future resolveWithResult:@YES];
  });

  NSError *error = nil;
  id value = [future awaitWithTimeout:1 error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(value, @YES);
}

- (void)testAsyncErrorPropogation
{
  NSError *expected = [NSError errorWithDomain:@"foo" code:0 userInfo:nil];
  FBMutableFuture *future = FBMutableFuture.future;
  dispatch_async(self.queue, ^{
    [future resolveWithError:expected];
  });

  NSError *error = nil;
  id value = [future awaitWithTimeout:1 error:&error];
  XCTAssertNil(value);
  XCTAssertEqualObjects(error, expected);
}

- (void)testChainValueThenError
{
  XCTestExpectation *step1 = [[XCTestExpectation alloc] initWithDescription:@"chain1 is called"];
  XCTestExpectation *step2 = [[XCTestExpectation alloc] initWithDescription:@"chain2 is called"];
  XCTestExpectation *step3 = [[XCTestExpectation alloc] initWithDescription:@"chain3 is called"];
  XCTestExpectation *step4 = [[XCTestExpectation alloc] initWithDescription:@"Completion is called"];
  NSError *error = [NSError errorWithDomain:@"foo" code:2 userInfo:nil];

  FBMutableFuture<NSNumber *> *baseFuture = FBMutableFuture.future;
  FBFuture<NSNumber *> *chainFuture = [[[[baseFuture
    onQueue:self.queue chain:^(FBFuture *future) {
      XCTAssertEqualObjects(future.result, @1);
      [step1 fulfill];
      return [FBFuture futureWithResult:@2];
    }]
    onQueue:self.queue chain:^(FBFuture *future) {
      XCTAssertEqualObjects(future.result, @2);
      [step2 fulfill];
      return [FBFuture futureWithError:error];
    }]
    onQueue:self.queue chain:^FBFuture *(FBFuture *future) {
      XCTAssertEqualObjects(future.error, error);
      [step3 fulfill];
      return [FBFuture futureWithResult:@4];
    }]
    onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
      XCTAssertEqualObjects(future.result, @4);
      [step4 fulfill];
    }];
  dispatch_async(self.queue, ^{
    [baseFuture resolveWithResult:@1];
  });

  [self waitForExpectations:@[step1, step2, step3, step4] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(chainFuture.state, FBFutureStateDone);
  XCTAssertEqualObjects(chainFuture.result, @4);
}

- (void)testChainValueThenCancel
{
  XCTestExpectation *completion = [[XCTestExpectation alloc] initWithDescription:@"Completion is called"];

  FBMutableFuture<NSNumber *> *baseFuture = FBMutableFuture.future;
  FBFuture<NSNumber *> *chainFuture = [[[baseFuture
    onQueue:self.queue chain:^(FBFuture *future) {
      XCTFail(@"Chain Should Not be called for cancelled future");
      return [FBFuture futureWithResult:@2];
    }]
    onQueue:self.queue fmap:^(id _) {
     XCTFail(@"fmap Should Not be called for cancelled future");
     return [FBFuture futureWithResult:@3];
    }]
    onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
      XCTAssertEqual(future.state, FBFutureStateCancelled);
      [completion fulfill];
    }];
  dispatch_async(self.queue, ^{
    [baseFuture cancel];
  });

  [self waitForExpectations:@[completion] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(chainFuture.state, FBFutureStateCancelled);
}

- (void)testChainedCancellation
{
  XCTestExpectation *chain = [[XCTestExpectation alloc] initWithDescription:@"chain is called"];
  XCTestExpectation *completion = [[XCTestExpectation alloc] initWithDescription:@"Completion is called"];

  FBMutableFuture<NSNumber *> *baseFuture = FBMutableFuture.future;
  FBFuture<NSNumber *> *chainFuture = [[[baseFuture
    onQueue:self.queue chain:^(FBFuture *_) {
      [chain fulfill];
      FBMutableFuture *future = FBMutableFuture.future;
      [future cancel];
      return future;
    }]
    onQueue:self.queue chain:^(id _) {
      XCTFail(@"chain Should Not be called for cancelled future");
      return [FBFuture futureWithResult:@3];
    }]
    onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
      XCTAssertEqual(future.state, FBFutureStateCancelled);
      [completion fulfill];
    }];
  dispatch_async(self.queue, ^{
    [baseFuture resolveWithResult:@0];
  });

  [self waitForExpectations:@[chain, completion] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(chainFuture.state, FBFutureStateCancelled);
}

- (void)testRaceSuccessFutures
{
  XCTestExpectation *completion = [[XCTestExpectation alloc] initWithDescription:@"Completion is called"];
  XCTestExpectation *late1Cancelled = [[XCTestExpectation alloc] initWithDescription:@"Cancellation of late future 1"];
  XCTestExpectation *late2Cancelled = [[XCTestExpectation alloc] initWithDescription:@"Cancellation of late future 2"];

  FBFuture<NSNumber *> *lateFuture1 = [[FBMutableFuture
    future]
    onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
      XCTAssertEqual(future.state, FBFutureStateCancelled);
      [late1Cancelled fulfill];
    }];
  FBFuture<NSNumber *> *lateFuture2 = [[FBMutableFuture
    future]
    onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
      XCTAssertEqual(future.state, FBFutureStateCancelled);
      [late2Cancelled fulfill];
    }];
  FBFuture<NSNumber *> *raceFuture = [[FBFuture
    race:@[
      lateFuture1,
      [FBFuture futureWithResult:@1],
      lateFuture2,
    ]]
    onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
      XCTAssertEqual(future.state, FBFutureStateDone);
      XCTAssertEqualObjects(future.result, @1);
      [completion fulfill];
    }];

  [self waitForExpectations:@[completion, late1Cancelled, late2Cancelled] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(raceFuture.state, FBFutureStateDone);
  XCTAssertEqualObjects(raceFuture.result, @1);
  XCTAssertEqual(lateFuture1.state, FBFutureStateCancelled);
  XCTAssertEqual(lateFuture2.state, FBFutureStateCancelled);
}

- (void)testAllCancelledPropogates
{
  XCTestExpectation *completion = [[XCTestExpectation alloc] initWithDescription:@"Completion is called"];
  XCTestExpectation *cancel1Called = [[XCTestExpectation alloc] initWithDescription:@"Cancellation of late future 1"];
  XCTestExpectation *cancel2Called = [[XCTestExpectation alloc] initWithDescription:@"Cancellation of late future 2"];
  XCTestExpectation *cancel3Called = [[XCTestExpectation alloc] initWithDescription:@"Cancellation of late future 3"];

  FBFuture<NSNumber *> *cancelFuture1 = [[FBMutableFuture
    future]
    onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
      XCTAssertEqual(future.state, FBFutureStateCancelled);
      [cancel1Called fulfill];
    }];
  FBFuture<NSNumber *> *cancelFuture2 = [[FBMutableFuture
    future]
    onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
      XCTAssertEqual(future.state, FBFutureStateCancelled);
      [cancel2Called fulfill];
    }];
  FBFuture<NSNumber *> *cancelFuture3 = [[FBMutableFuture
    future]
      onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
        XCTAssertEqual(future.state, FBFutureStateCancelled);
      [cancel3Called fulfill];
    }];

  FBFuture<NSNumber *> *raceFuture = [[FBFuture
    race:@[
      cancelFuture1,
      cancelFuture2,
      cancelFuture3,
    ]]
    onQueue:self.queue notifyOfCompletion:^(FBFuture *future) {
      XCTAssertEqual(future.state, FBFutureStateCancelled);
      [completion fulfill];
    }];

  dispatch_async(self.queue, ^{
    [cancelFuture1 cancel];
  });
  dispatch_async(self.queue, ^{
    [cancelFuture2 cancel];
  });
  dispatch_async(self.queue, ^{
    [cancelFuture3 cancel];
  });

  [self waitForExpectations:@[completion, cancel1Called, cancel2Called, cancel3Called] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(raceFuture.state, FBFutureStateCancelled);
  XCTAssertEqual(cancelFuture1.state, FBFutureStateCancelled);
  XCTAssertEqual(cancelFuture2.state, FBFutureStateCancelled);
  XCTAssertEqual(cancelFuture3.state, FBFutureStateCancelled);
}

- (void)testImmediateValue
{
  NSError *error = [NSError errorWithDomain:@"foo" code:0 userInfo:nil];
  FBFuture<NSNumber *> *successFuture = [FBFuture futureWithResult:@1];
  FBFuture<NSNumber *> *errorFuture = [FBFuture futureWithError:error];

  XCTAssertEqual(successFuture.state, FBFutureStateDone);
  XCTAssertEqualObjects(successFuture.result, @1);
  XCTAssertEqual(errorFuture.state, FBFutureStateFailed);
  XCTAssertEqualObjects(errorFuture.error, error);
}

- (void)testImmedateValueInRaceBasedOnOrdering
{
  NSError *error = [NSError errorWithDomain:@"foo" code:0 userInfo:nil];
  FBFuture<NSNumber *> *raceFuture = [FBFuture race:@[
    [FBFuture futureWithResult:@1],
    [FBFuture futureWithError:error],
    [FBMutableFuture future],
  ]];
  XCTAssertEqual(raceFuture.state, FBFutureStateDone);
  XCTAssertEqualObjects(raceFuture.result, @1);

  raceFuture = [FBFuture race:@[
    [FBFuture futureWithError:error],
    [FBMutableFuture future],
    [FBFuture futureWithResult:@2],
  ]];
  XCTAssertEqual(raceFuture.state, FBFutureStateFailed);
  XCTAssertEqualObjects(raceFuture.error, error);
}

- (void)testAsyncConstructor
{
  XCTestExpectation *resultCalled = [[XCTestExpectation alloc] initWithDescription:@"Result Future"];
  XCTestExpectation *errorCalled = [[XCTestExpectation alloc] initWithDescription:@"Error Future"];
  XCTestExpectation *cancelCalled = [[XCTestExpectation alloc] initWithDescription:@"Cancel Future"];

  NSError *error = [NSError errorWithDomain:@"foo" code:0 userInfo:nil];
  FBFuture *resultFuture = [FBFuture onQueue:self.queue resolve:^FBFuture *{
    [resultCalled fulfill];
    return [FBFuture futureWithResult:@0];
  }];
  FBFuture *errorFuture = [FBFuture onQueue:self.queue resolve:^FBFuture *{
    [errorCalled fulfill];
    return [FBFuture futureWithError:error];
  }];
  FBFuture *cancelFuture = [FBFuture onQueue:self.queue resolve:^FBFuture *{
    [cancelCalled fulfill];
    FBMutableFuture *future = [FBMutableFuture future];
    [future cancel];
    return future;
  }];

  [self waitForExpectations:@[resultCalled, errorCalled, cancelCalled] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(resultFuture.state, FBFutureStateDone);
  XCTAssertEqual(errorFuture.state, FBFutureStateFailed);
  XCTAssertEqual(cancelFuture.state, FBFutureStateCancelled);
}

- (void)testTimedOutIn
{
  FBFuture *future = [[FBFuture new] timeout:0.1 waitingFor:@"Some Condition"];

  XCTAssertFalse(future.hasCompleted);
  XCTAssertEqual(future.state, FBFutureStateRunning);
  XCTAssertNil(future.result);
  XCTAssertNil(future.error);

  [self waitForExpectations:@[
    [self keyValueObservingExpectationForObject:future keyPath:@"hasCompleted" expectedValue:@YES],
    [self keyValueObservingExpectationForObject:future keyPath:@"state" expectedValue:@(FBFutureStateFailed)]
  ] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
}

- (void)testResolveWhen
{
  __block NSInteger resolveCount = 2;
  FBFuture<NSNull *> *future = [FBFuture onQueue:self.queue resolveWhen:^BOOL {
    --resolveCount;
    return resolveCount == 0;
  }];

  [self waitForExpectations:@[
    [self keyValueObservingExpectationForObject:future keyPath:@"hasCompleted" expectedValue:@YES],
    [self keyValueObservingExpectationForObject:future keyPath:@"result" expectedValue:@YES],
    [self keyValueObservingExpectationForObject:future keyPath:@"state" expectedValue:@(FBFutureStateDone)]
  ] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
}

- (void)testReplaceFuture
{
  FBMutableFuture<NSNumber *> *replacement = FBMutableFuture.future;
  FBFuture<NSNumber *> *future = [[[FBFuture futureWithResult:@NO] fmapReplace:replacement] delay:0.1];
  dispatch_async(self.queue, ^{
    [replacement resolveWithResult:@YES];
  });

  [self waitForExpectations:@[
    [self keyValueObservingExpectationForObject:future keyPath:@"result" expectedValue:@YES],
    [self keyValueObservingExpectationForObject:future keyPath:@"state" expectedValue:@(FBFutureStateDone)]
  ] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
}

- (void)testFallback
{
  NSError *error = [NSError errorWithDomain:@"foo" code:0 userInfo:nil];
  FBFuture<NSNumber *> *future = [[[FBFuture futureWithError:error] fallback:@YES] delay:0.1];

  [self waitForExpectations:@[
    [self keyValueObservingExpectationForObject:future keyPath:@"result" expectedValue:@YES],
    [self keyValueObservingExpectationForObject:future keyPath:@"state" expectedValue:@(FBFutureStateDone)]
  ] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
}

- (void)testRepeatedResolution
{
  XCTestExpectation *completionCalled = [[XCTestExpectation alloc] initWithDescription:@"Resolved outer Completion"];
  NSError *error = [NSError errorWithDomain:@"foo" code:2 userInfo:nil];
  NSArray<FBFuture<NSNumber *> *> *futures = @[
    [FBFuture futureWithError:error],
    [FBFuture futureWithError:error],
    [FBFuture futureWithError:error],
    [FBFuture futureWithResult:@YES],
  ];
  __block NSUInteger index = 0;
  FBFuture<NSNumber *> *future = [FBFuture onQueue:self.queue resolveUntil:^{
    FBFuture<NSNumber *> *inner = futures[index];
    index++;
    return inner;
  }];
  [future onQueue:self.queue notifyOfCompletion:^(FBFuture<NSNumber *> *inner) {
    [completionCalled fulfill];
    XCTAssertEqualObjects(inner.result, @YES);
  }];

  [self waitForExpectations:@[completionCalled] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(future.state, FBFutureStateDone);
  XCTAssertEqualObjects(future.result, @YES);
}

- (void)testCancelledResolution
{
  XCTestExpectation *completionCalled = [[XCTestExpectation alloc] initWithDescription:@"Resolved outer Completion"];
  NSError *error = [NSError errorWithDomain:@"foo" code:2 userInfo:nil];
  FBFuture<NSNumber *> *cancelledFuture = [FBMutableFuture future];
  [cancelledFuture cancel];
  NSArray<FBFuture<NSNumber *> *> *futures = @[
    [FBFuture futureWithError:error],
    cancelledFuture,
    [FBFuture futureWithError:error],
    [FBFuture futureWithError:error],
  ];
  __block NSUInteger index = 0;
  FBFuture<NSNumber *> *future = [FBFuture onQueue:self.queue resolveUntil:^{
    FBFuture<NSNumber *> *inner = futures[index];
    index++;
    return inner;
  }];
  [future onQueue:self.queue notifyOfCompletion:^(FBFuture<NSNumber *> *inner) {
    [completionCalled fulfill];
    XCTAssertEqual(inner.state, FBFutureStateCancelled);
  }];

  [self waitForExpectations:@[completionCalled] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(future.state, FBFutureStateCancelled);
}

- (void)testAsynchronousCancellationPropogates
{
  XCTestExpectation *respondCalled = [[XCTestExpectation alloc] initWithDescription:@"Resolved Responding to Cancellation"];
  XCTestExpectation *cancellationCallbackCalled = [[XCTestExpectation alloc] initWithDescription:@"Resolved Cancellation finished"];
  FBFuture<NSNumber *> *future = [[FBMutableFuture
    future]
    onQueue:self.queue respondToCancellation:^{
      [respondCalled fulfill];
      return [FBFuture futureWithResult:NSNull.null];
    }];

  [[future
    cancel]
    onQueue:self.queue notifyOfCompletion:^(id _) {
      [cancellationCallbackCalled fulfill];
    }];

  [self waitForExpectations:@[respondCalled, cancellationCallbackCalled] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
  XCTAssertEqual(future.state, FBFutureStateCancelled);
}

- (void)testCallingCancelTwiceReturnsTheSameCancellationFuture
{
  XCTestExpectation *respondCalled = [[XCTestExpectation alloc] initWithDescription:@"Resolved Responding to Cancellation"];

  FBFuture<NSNumber *> *future = [[FBMutableFuture
    future]
    onQueue:self.queue respondToCancellation:^{
      [respondCalled fulfill];
      return [FBFuture futureWithResult:NSNull.null];
    }];

  FBFuture<NSNull *> *cancelledFirstTime = [future cancel];
  FBFuture<NSNull *> *cancelledSecondTime = [future cancel];
  XCTAssertEqual(cancelledFirstTime, cancelledSecondTime);
}

- (void)testInstallingCancellationHandlerTwiceWillOnlyCallFirstCancellationHandler
{
  XCTestExpectation *firstCancelCalled = [[XCTestExpectation alloc] initWithDescription:@"Resolved Responding to Cancellation"];
  XCTestExpectation *completionCalled = [[XCTestExpectation alloc] initWithDescription:@"Resolved Completion"];

  FBFuture<NSNumber *> *future = [[[[FBMutableFuture
    future]
    onQueue:self.queue respondToCancellation:^{
      [firstCancelCalled fulfill];
      return [FBFuture futureWithResult:NSNull.null];
    }]
    onQueue:self.queue respondToCancellation:^{
      XCTFail(@"Second Cancellation should not have been called");
      return [FBFuture futureWithResult:NSNull.null];
    }]
    onQueue:self.queue notifyOfCompletion:^(FBFuture<NSNull *> *completionFuture) {
      XCTAssertEqual(completionFuture.state, FBFutureStateCancelled);
      [completionCalled fulfill];
    }];

  [future cancel];
  [self waitForExpectations:@[firstCancelCalled, completionCalled] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
}

- (void)testCancellationHandlerIsNotCalledIfFutureIsNotCancelled
{
  XCTestExpectation *completionCalled = [[XCTestExpectation alloc] initWithDescription:@"Resolved Completion"];

  FBMutableFuture<NSNull *> *baseFuture = FBMutableFuture.future;
  [[baseFuture
    onQueue:self.queue respondToCancellation:^{
      XCTFail(@"Cancellation should not have been called");
      return [FBFuture futureWithResult:NSNull.null];
    }]
    onQueue:self.queue notifyOfCompletion:^(FBFuture<NSNull *> *completionFuture) {
      XCTAssertEqual(completionFuture.state, FBFutureStateDone);
      [completionCalled fulfill];
    }];

  [baseFuture resolveWithResult:NSNull.null];
  [baseFuture cancel];

  [self waitForExpectations:@[completionCalled] timeout:FBControlCoreGlobalConfiguration.fastTimeout];
}

#pragma mark - Helpers

- (void)assertSynchronousResolutionWithBlock:(void (^)(FBMutableFuture *))resolveBlock expectedState:(FBFutureState)state expectedResult:(id)expectedResult expectedError:(NSError *)expectedError
{
  FBMutableFuture<NSNumber *> *future = FBMutableFuture.future;

  resolveBlock(future);

  XCTAssertEqual(future.state, state);
  XCTAssertEqual(future.hasCompleted, YES);
  XCTAssertEqual(future.result, expectedResult);
  XCTAssertEqual(future.error, expectedError);
}

- (void)waitForAsynchronousResolutionWithBlock:(void (^)(FBMutableFuture *))resolveBlock expectedState:(FBFutureState)state expectationKeyPath:(NSString *)expectationKeyPath expectationValue:(id)expectationValue
{
  FBMutableFuture<NSNumber *> *future = FBMutableFuture.future;
  NSArray *expectations = @[
    [self keyValueObservingExpectationForObject:future keyPath:@"state" expectedValue:@(state)],
    [self keyValueObservingExpectationForObject:future keyPath:@"hasCompleted" expectedValue:@YES],
  ];

  if (expectationKeyPath != nil) {
    expectations = [expectations arrayByAddingObject:[self keyValueObservingExpectationForObject:future keyPath:expectationKeyPath expectedValue:expectationValue]];
  }

  dispatch_async(self.queue, ^{
    resolveBlock(future);
  });

  [self waitForExpectations:expectations timeout:FBControlCoreGlobalConfiguration.fastTimeout];
}

@end
