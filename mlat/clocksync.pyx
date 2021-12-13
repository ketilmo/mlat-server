#!python
#cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, nonecheck=False

# -*- mode: python; indent-tabs-mode: nil -*-

# Part of mlat-server: a Mode S multilateration server
# Copyright (C) 2015  Oliver Jowett <oliver@mutability.co.uk>

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

"""
Maintains clock synchronization between individual pairs of receivers.
"""

import bisect
import logging

# cython stuff:
from libc.string cimport memmove
from libc.math cimport sqrt

from mlat import config, constants

__all__ = ('Clock', 'ClockPairing', 'make_clock')

glogger = logging.getLogger("clocksync")

cdef class Clock(object):
    """A particular clock. Stores characteristics of a clock,
    and acts as part of the key in the clock pairing map.
    """

    cdef readonly double freq
    cdef readonly double max_freq_error
    cdef readonly double jitter
    cdef readonly double delayFactor

    def __init__(self, freq, max_freq_error, jitter):
        """Create a new clock representation.

        freq: the clock frequency in Hz (float)
        max_freq_error: the maximum expected relative frequency error (i.e. 1e-6 is 1PPM) (float)
        jitter: the expected jitter of a typical reading, in seconds, standard deviation  (float)
        """
        self.freq = freq
        self.max_freq_error = max_freq_error
        self.jitter = jitter
        self.delayFactor = freq / constants.Cair


def make_clock(clock_type):
    """Return a new Clock instance for the given clock type."""

    if clock_type == 'radarcape_gps':
        return Clock(freq=1e9, max_freq_error=1e-6, jitter=15e-9)
    if clock_type == 'beast' or clock_type == 'radarcape_12mhz':
        return Clock(freq=12e6, max_freq_error=5e-6, jitter=83e-9)
    if clock_type == 'sbs':
        return Clock(freq=20e6, max_freq_error=100e-6, jitter=500e-9)
    if clock_type == 'dump1090' or clock_type == 'unknown':
        return Clock(freq=12e6, max_freq_error=100e-6, jitter=500e-9)
    raise NotImplementedError("{ct}".format(ct=clock_type))

cdef int cp_size = 32

cdef int drift_n_stable = 12

cdef class ClockPairing(object):
    """Describes the current relative characteristics of a pair of clocks."""

    cdef readonly bint valid
    cdef readonly double updated
    cdef readonly double update_attempted
    cdef readonly double variance
    cdef base
    cdef peer
    cdef public int cat
    cdef base_clock
    cdef peer_clock
    cdef double base_freq
    cdef double peer_freq
    cdef readonly double raw_drift
    cdef readonly double drift
    cdef readonly double i_drift
    cdef readonly int drift_n
    cdef int drift_outliers
    cdef readonly int n
    cdef readonly int outlier_reset_cooldown
    cdef readonly double outlier_total
    cdef readonly double update_total
    # needs to be cp_size big, can't use it here though
    cdef double ts_base[32]
    cdef double ts_peer[32]
    cdef double var[32]
    cdef double var_sum
    cdef readonly int outliers
    cdef double cumulative_error
    cdef readonly double error

    cdef public int jumped

    cdef double relative_freq
    cdef double i_relative_freq
    cdef double drift_max
    cdef double drift_max_delta
    cdef double outlier_threshold


    def __init__(self, base, peer, cat):
        self.base = base
        self.peer = peer
        self.cat = cat
        self.base_clock = base.clock
        self.peer_clock = peer.clock
        self.base_freq = base.clock.freq
        self.peer_freq = peer.clock.freq

        self.relative_freq = peer.clock.freq / base.clock.freq
        self.i_relative_freq = base.clock.freq / peer.clock.freq
        self.drift_max = 0.75 * (base.clock.max_freq_error + peer.clock.max_freq_error)
        self.drift_max_delta = self.drift_max / 10.0
        # self.outlier_threshold = 4 * sqrt(peer.clock.jitter ** 2 + base.clock.jitter ** 2) # 4 sigma
        # this was about 2.5 us for rtl-sdr receivers
        self.outlier_threshold = 0.9 * 1e-6 # 1e-6 -> 1 us

        self.updated = 0
        self.update_attempted = 0

        self.raw_drift = 0
        self.drift = 0
        self.i_drift = 0
        self.drift_outliers = 0

        self.outliers = 0
        self.jumped = 0

        self.outlier_reset_cooldown = 5 # number of sync pair updates before this sync pair can be trusted

        self.valid = False
        self.n = 0
        self.var_sum = 0.0
        self.cumulative_error = 0.0
        self.error = -1e-6
        self.variance = -1e-6

        self.outlier_total = 0
        self.update_total = 1e-3

    cpdef bint check_valid(self, double now):
        if self.n < 2 or self.drift_n < 2:
            self.variance = -1e-6
            self.error = -1e-6
            self.valid = False
            return False

        """Variance of recent predictions of the sync point versus the actual sync point."""
        self.variance = self.var_sum / self.n
        """Standard error of recent predictions."""
        self.error = sqrt(self.variance)

        """True if this pairing is usable for clock syncronization."""
        self.valid = (self.outlier_reset_cooldown < 1
                and self.n > 4
                and self.drift_n > 4
                and self.variance < 16e-12
                and now - self.updated < 35.0)
        return self.valid

    def update(self, address, double base_ts, double peer_ts, double base_interval, double peer_interval, double now, ac):
        """Update the relative drift and offset of this pairing given:

        address: the ICAO address of the sync aircraft, for logging purposes
        base_ts: the timestamp of a recent point in time measured by the base clock
        peer_ts: the timestamp of the same point in time measured by the peer clock
        base_interval: the duration of a recent interval measured by the base clock
        peer_interval: the duration of the same interval measured by the peer clock

        Returns True if the update was used, False if it was an outlier.
        """
        cdef double prediction = 0
        cdef double prediction_error = 0
        cdef bint outlier = False
        cdef bint do_reset = False
        cdef double outlier_threshold

        # clean old data
        if self.n > cp_size - 1 or base_ts - self.ts_base[0] > 50.0 * self.base_freq:
            self._prune_old_data(now)

        self.update_total += 1
        self.update_attempted = now

        if self.n > 0 and not outlier:
            # ts_base and ts_peer define a function constructed by linearly
            # interpolating between each pair of values.
            #
            # This function must be monotonically increasing or one of our clocks
            # has effectively gone backwards. If this happens, give up and start
            # again.

            if peer_ts <= self.ts_peer[self.n - 1] or base_ts <= self.ts_base[self.n - 1]:
                if peer_ts < self.ts_peer[self.n - 1] and base_ts < self.ts_base[self.n - 1]:
                    return False
                if peer_ts == self.ts_peer[self.n - 1] or base_ts == self.ts_base[self.n - 1]:
                    return False

                # just in case, make this pair invalid for the moment
                # the next update will set it to valid again
                self.valid = False

                self.outliers += 10
                outlier = True
                self.outlier_total += 1

                if self.outliers <= 10:
                    # don't reset quite yet, maybe something strange was unique
                    return False

        cdef double abs_error
        # predict from existing data, compare to actual value
        if self.n > 0 and not outlier:
            prediction = self.predict_peer(base_ts)
            prediction_error = (prediction - peer_ts) / self.peer_freq

            #if abs(prediction_error) > self.outlier_threshold and abs(prediction_error) > self.error * 4 : # 4 sigma

            if self.n >= 4:
                outlier_threshold = self.outlier_threshold
            else:
                outlier_threshold = 2.0 * self.outlier_threshold

            abs_error = abs(prediction_error)
            self.base.num_syncs += 1
            self.peer.num_syncs += 1
            if abs_error > outlier_threshold:
                if self.peer.bad_syncs < 0.01 and self.base.bad_syncs < 0.01:
                    ac.sync_bad += 1

                if ac.sync_dont_use:
                    return False

                if self.peer.bad_syncs < 0.01:
                    self.base.num_outliers += 1
                if self.base.bad_syncs < 0.01:
                    self.peer.num_outliers += 1

                outlier = True
                self.outlier_total += 1
                if abs_error > 2 * outlier_threshold:
                    self.outliers += 20
                    do_reset = True
                else:
                    self.outliers += 8

                if self.outliers <= 77:
                    return False


                if abs_error > 2 * outlier_threshold:
                    if not self.jumped:
                        if self.peer.bad_syncs < 0.01:
                            self.base.incrementJumps()
                        if self.base.bad_syncs < 0.01:
                            self.peer.incrementJumps()

                    self.jumped = 1
            else:
                ac.sync_good += 1

            if self.n >= 2:
                # wiedehopf: add hacky sync averaging
                # modify new base_ts and peer_ts towards the geometric mean between predition and actual value
                # changing the prediction functions to take into account more past values would likely be the cleaner approach
                # but this modification is significantly easier in regards to the code required
                # so far it seems to be working quite well
                # note that using weight 1/2 so the exact geometric mean seems to be unstable
                # weights 1/4 and 1/3 seem to work well though
                prediction_base = self.predict_base(peer_ts)
                if self.n >= 4 and self.drift_n > drift_n_stable:
                    peer_ts += (prediction - peer_ts) * 0.38
                    base_ts += (prediction_base - base_ts) * 0.38
                else:
                    peer_ts += (prediction - peer_ts) * 0.15
                    base_ts += (prediction_base - base_ts) * 0.15

        if ac.sync_dont_use:
            return False

        cdef double outlier_percent
        if outlier and do_reset:
            if (self.peer.focus and self.base.bad_syncs < 0.01) or (self.base.focus and self.peer.bad_syncs < 0.01):
                outlier_percent = 100.0 * self.outlier_total / self.update_total
                glogger.warning("ac {a:06X} step_us {e:.1f} drift_ppm {d:.1f} outlier_percent {o:.3f} pair: {r}".format(
                    r=self,
                    a=address,
                    e=prediction_error*1e6,
                    o=outlier_percent,
                    d=self.drift*1e6))
            #if self.peer.bad_syncs < 0.1 and self.base.bad_syncs < 0.1:
            #   glogger.warning("{r}: {a:06X}: step by {e:.1f}us".format(r=self, a=address, e=prediction_error*1e6))

            # outlier .. we need to reset this clock pair
            self.reset_offsets()
            self.outlier_reset_cooldown = 15 # number of sync pair updates before this sync pair can be trusted
            # as we just reset everything, this is the first point and the prediction error is zero
            prediction_error = 0

        self.outliers = max(0, self.outliers - 18)

        self.cumulative_error = max(-50e-6, min(50e-6, self.cumulative_error + prediction_error))  # limit to 50us

        self.outlier_reset_cooldown = max(0, self.outlier_reset_cooldown - 1)

        # update clock drift based on interval ratio
        # this might reject the update
        if not self._update_drift(base_interval, peer_interval):
            self.check_valid(now)
            return False

        # update clock offset based on the actual clock values
        self._update_offset(base_ts, peer_ts, prediction_error)

        self.updated = now
        self.check_valid(now)
        return True

    cdef void _prune_old_data(self, double now):
        cdef int i = 0

        if self.outlier_total or self.update_total > 256:
            self.outlier_total /= 2
            self.update_total /= 2

        cdef int new_max = cp_size - 12
        if self.n > new_max:
            i = self.n - new_max

        cdef double latest_base_ts = self.ts_base[self.n - 1]
        cdef double limit = 45.0 * self.base_freq
        while i < self.n and (latest_base_ts - self.ts_base[i]) > limit:
            i += 1

        if i > 0:
            self.n -= i
            memmove(self.ts_base, self.ts_base + i, self.n * sizeof(double))
            memmove(self.ts_peer, self.ts_peer + i, self.n * sizeof(double))
            memmove(self.var, self.var + i, self.n * sizeof(double))
            self.var_sum = 0
            for k in range(self.n):
                self.var_sum += self.var[k]
            self.check_valid(now)

    cdef bint _update_drift(self, double base_interval, double peer_interval):
        # try to reduce the effects of catastropic cancellation here:
        #new_drift = (peer_interval / base_interval) / self.relative_freq - 1.0
        cdef double adjusted_base_interval = base_interval * self.relative_freq
        cdef double new_drift = (peer_interval - adjusted_base_interval) / adjusted_base_interval

        if abs(new_drift) > self.drift_max:
            # Bad data, ignore entirely
            #glogger.warn("{0}: drift_max".format(self))
            return False

        if self.drift_n <= 0 or self.drift_outliers > 30:
            # First sample, just trust it outright
            self.raw_drift = self.drift = new_drift
            self.i_drift = -1 * self.drift / (1.0 + self.drift)
            self.drift_n = 0
            self.cumulative_error = 0.0
            self.drift_outliers = 0

        if self.drift_n <= 0:
            # First sample, just trust it outright
            self.raw_drift = self.drift = new_drift
            self.i_drift = -1 * self.drift / (1.0 + self.drift)
            # give this a bit of confidence
            self.drift_n = 2
            return True

        cdef double drift_error = new_drift - self.raw_drift
        if abs(drift_error) > self.drift_max_delta:
            # Too far away from the value we expect, discard
            #glogger.warn("{0}: drift_max_delta".format(self))
            if self.peer.focus or self.base.focus:
                glogger.warn("{r}: drift_error_ppm out of limits: {de:.1f}".format(r=self, de=1e6*drift_error))
            self.drift_outliers += 1
            return False

        self.drift_outliers = max(0, self.drift_outliers - 2)

        cdef double KP = 0.03
        cdef double KI = 0.008

        # for relatively new pairs allow quicker adjustment of relative drift
        cdef double adjustment_factor
        if self.drift_n < drift_n_stable:
            adjustment_factor = 1 + (0.3 / KP) * ((drift_n_stable - self.drift_n) / drift_n_stable)
            KP *= adjustment_factor

        self.drift_n += 1

        # move towards the new value
        self.raw_drift += drift_error * KP
        self.drift = self.raw_drift - KI * self.cumulative_error
        self.i_drift = -1 * self.drift / (1.0 + self.drift)
        return True

    cpdef void reset_offsets(self):
        self.valid = False
        self.n = 0
        self.var_sum = 0.0
        self.error = -1e-6
        self.variance = -1e-6
        self.outliers = 0
        self.cumulative_error = 0.0

    cdef void _update_offset(self, double base_ts, double peer_ts, double prediction_error):
        # insert this into self.ts_base / self.ts_peer / self.var in the right place

        cdef double p_var = prediction_error * prediction_error

        self.ts_base[self.n] = base_ts
        self.ts_peer[self.n] = peer_ts
        self.var[self.n] = p_var

        self.n += 1

        self.var_sum += p_var


    cpdef double predict_peer(self, double base_ts):
        """
        Given a time from the base clock, predict the time of the peer clock.
        """

        cdef int n = self.n
        if n == 0:
            raise ValueError("predict_peer called on n == 0 clock pair")

        if base_ts < self.ts_base[0] or n == 1:
            # extrapolate before first point or if we only have one point
            elapsed = base_ts - self.ts_base[0]
            return self.ts_peer[0] + elapsed * self.relative_freq * (1 + self.drift)

        if base_ts > self.ts_base[n-1] - 10 * self.base_freq:
            # extrapolate using last point when after 10 seconds before last point (avoid bisect due to cost)
            elapsed = base_ts - self.ts_base[n-1]
            result = self.ts_peer[n-1] + elapsed * self.relative_freq * (1 + self.drift)

            if self.ts_base[n-1] - self.ts_base[n-2] > 10 * self.base_freq:
                return result

            # if the last 2 points are less than 10 seconds apart, average between extrapolations from those 2 points

            elapsed = base_ts - self.ts_base[n-2]
            result += self.ts_peer[n-2] + elapsed * self.relative_freq * (1 + self.drift)
            return result * 0.5

        i = bisect.bisect_left(self.ts_base, base_ts)
        # interpolate between two points
        return (self.ts_peer[i-1] +
                (self.ts_peer[i] - self.ts_peer[i-1]) *
                (base_ts - self.ts_base[i-1]) /
                (self.ts_base[i] - self.ts_base[i-1]))

    cpdef double predict_base(self, double peer_ts):
        """
        Given a time from the peer clock, predict the time of the base
        clock.
        """

        cdef int n = self.n
        if n == 0:
            raise ValueError("predict_base called on n == 0 clock pair")

        if peer_ts < self.ts_peer[0] or n == 1:
            # extrapolate before first point or if we only have one point
            elapsed = peer_ts - self.ts_peer[0]
            return self.ts_base[0] + elapsed * self.i_relative_freq * (1 + self.i_drift)

        if peer_ts > self.ts_peer[n-1] - 10 * self.peer_freq:
            # extrapolate using last point when after 10 seconds before last point (avoid bisect due to cost)
            elapsed = peer_ts - self.ts_peer[n-1]
            result = self.ts_base[n-1] + elapsed * self.i_relative_freq * (1 + self.i_drift)

            if self.ts_peer[n-1] - self.ts_peer[n-2] > 10 * self.peer_freq:
                return result

            # if the last 2 points are less than 10 seconds apart, average between extrapolations from those 2 points

            elapsed = peer_ts - self.ts_peer[n-2]
            result += self.ts_base[n-2] + elapsed * self.i_relative_freq * (1 + self.i_drift)
            return result * 0.5

        i = bisect.bisect_left(self.ts_peer, peer_ts)
        # interpolate between two points
        return (self.ts_base[i-1] +
                (self.ts_base[i] - self.ts_base[i-1]) *
                (peer_ts - self.ts_peer[i-1]) /
                (self.ts_peer[i] - self.ts_peer[i-1]))

    def __str__(self):
        return self.base.user + ':' + self.peer.user
