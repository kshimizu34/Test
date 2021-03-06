#!/usr/bin/env python
# -*- coding: utf-8 -*-
import numpy as np


class _EventHandlers(object):
    def __init__(self, events):
        super(_EventHandlers, self).__setattr__('_events', events)

    def __getattr__(self, name):
        def deco(f):
            self._events[name] = f
            return f

        return deco

    def __setattr__(self, name, f):
        self._events[name] = f

    def get_handlers(self):
        return self._evnets

# Default events


def default_event_start(trainer):
    pass


def default_event_start_epoch(trainer):
    try:
        from tqdm import tqdm
        iter_count = len(trainer.train_distributor) / trainer.batch_size
        bar = tqdm(total=iter_count)
    except:
        import warnings
        warnings.warn(
            "To display progress bar, you need to install 'tqdm' module.")
        bar = None
    setattr(trainer, "bar", bar)


def default_event_forward(trainer):
    pass


def default_event_backward(trainer):
    pass


def default_event_updated(trainer):
    bar = getattr(trainer, "bar", None)
    if bar is not None:
        epoch = trainer.epoch
        train_loss = trainer.loss.as_ndarray()
        msg = "epoch%3d: loss %6.4f" % (epoch, train_loss)
        bar.set_description(msg)
        bar.update(1)


def default_event_end_epoch(trainer):
    epoch = trainer.epoch
    bar = getattr(trainer, "bar", None)
    test_distributor = trainer.test_distributor
    avg_train_loss = trainer.avg_train_loss.as_ndarray()
    avg_test_loss = 0
    msg = "epoch%3d: avg loss %6.4f" % (epoch, avg_train_loss)

    if test_distributor:
        trainer.model.set_models(inference=True)
        for i, (data, target) in enumerate(test_distributor.batch(trainer.batch_size, trainer.shuffle)):
            test_loss = trainer.loss_func(trainer.model(data), target).as_ndarray()
            avg_test_loss += (test_loss - avg_test_loss) / (i + 1)
        msg = "epoch%3d: avg loss %6.4f: avg test loss %6.4f" % \
            (epoch, avg_train_loss, avg_test_loss)
        trainer.model.set_models(inference=False)
        trainer.test_loss_list.append(avg_test_loss)
    trainer.train_loss_list.append(avg_train_loss)

    if bar is not None:
        bar.set_description(msg)
        bar.update(0)
        bar.refresh()
        bar.close()
    else:
        print(msg)


class Trainer(object):
    """Trainer class.

    This class owns train loop. It executes forward propagation,
    back propagation and updating of weight parameters for the
    specified number of times.

    Args:
        model (Model): Model to be trained.
        num_epoch (int): Numer of iteration.
        loss_func (Node): Loss function.
        batch_size (int): Batch size.
        optimizer (Optimizer): Gradient descent algorithm.
        shuffle (bool): If it's true, mini batch is created randomly.
        events (dict): Dictionary of function.

    Example:
        >>> import numpy as np
        >>> import renom as rm
        >>> from renom.utility.trainer import Trainer
        >>> from renom.utility.distributor import NdarrayDistributor
        >>> x = np.random.rand(300, 50)
        >>> y = np.random.rand(300, 1)
        >>> model = rm.Dense(1)
        >>> trainer = Trainer(model, 10, rm.mean_squared_error, 3, rm.Sgd(0.1))
        >>> trainer.train(NdarrayDistributor(x, y))
        epoch  0: avg loss 0.1597: 100%|██████████| 100/100.0 [00:00<00:00, 1167.85it/s]
        epoch  1: avg loss 0.1131: 100%|██████████| 100/100.0 [00:00<00:00, 1439.25it/s]
        epoch  2: avg loss 0.1053: 100%|██████████| 100/100.0 [00:00<00:00, 1413.42it/s]
        epoch  3: avg loss 0.0965: 100%|██████████| 100/100.0 [00:00<00:00, 1388.67it/s]
        epoch  4: avg loss 0.0812: 100%|██████████| 100/100.0 [00:00<00:00, 1445.61it/s]
        epoch  5: avg loss 0.0937: 100%|██████████| 100/100.0 [00:00<00:00, 1432.99it/s]
        epoch  6: avg loss 0.0891: 100%|██████████| 100/100.0 [00:00<00:00, 1454.68it/s]
        epoch  7: avg loss 0.0992: 100%|██████████| 100/100.0 [00:00<00:00, 1405.73it/s]
        epoch  8: avg loss 0.0933: 100%|██████████| 100/100.0 [00:00<00:00, 1401.55it/s]
        epoch  9: avg loss 0.1090: 100%|██████████| 100/100.0 [00:00<00:00, 1343.97it/s]

    """

    def __init__(self, model, num_epoch, loss_func, batch_size,
                 optimizer=None, shuffle=True, events=None):

        self.model = model
        self.num_epoch = num_epoch
        self.loss_func = loss_func
        self.batch_size = batch_size
        self.optimizer = optimizer
        self.shuffle = shuffle
        self.train_loss_list = []
        self.test_loss_list = []

        if events:
            self._events = events.copy()
        else:
            self._events = {
                "start": default_event_start,
                "start_epoch": default_event_start_epoch,
                "forward": default_event_forward,
                "backward": default_event_backward,
                "updated": default_event_updated,
                "end_epoch": default_event_end_epoch
            }

        self.events = _EventHandlers(self._events)

    def on_event(self, event):
        handler = self._events.get(event)
        if handler:
            handler(self)

    def train(self, train_distributor, test_distributor=None):
        """Train method.
        This method executes train loop.
        If test_distributor is given, validation loss will be calculated.

        Args:
            train_distributor (Distributor): Distributor for yielding train data.
            test_distributor (Distributor): Distributor for yielding test data.
        """
        self.epoch = 0
        self.train_distributor = train_distributor
        self.test_distributor = test_distributor
        self.on_event('start')
        self.train_loss_list = []
        self.test_loss_list = []

        while self.epoch < self.num_epoch:
            self.on_event('start_epoch')
            self.nth = 0
            self.avg_train_loss = 0

            for i, (data, target) in enumerate(self.train_distributor.batch(self.batch_size, self.shuffle)):
                self.data = data
                self.target = target
                self.on_event('forward')

                self.model.set_models(inference=False)

                with self.model.train():
                    self.output = self.model(self.data)
                    self.loss = self.loss_func(self.output, self.target)
                self.avg_train_loss += (self.loss -
                                        self.avg_train_loss) / (i + 1)

                self.on_event('backward')
                self.grads = self.loss.grad()
                self.grads.update(self.optimizer)
                self.on_event('updated')
                self.nth += 1

                # release objects
                self.data = self.target = None
                self.output = self.loss = self.grads = None

            self.on_event('end_epoch')
            self.epoch += 1

            # release objects
            self.avg_train_loss = None

    def test(self, data):
        """Test method.
        This method executes forward propagation for given data.

        Args:
            data (ndarray): Input data.

        Returns:
            ndarray
        """
        bs = self.batch_size
        N = len(data) - 1 + bs
        self.model.set_models(inference=True)
        ret = np.vstack([self.model(data[bs * i:bs * (i + 1)]).as_ndarray()
                         for i in range(N // bs)])
        self.model.set_models(inference=False)
        return ret
