
import sys
from libc.stdlib cimport malloc, free
from libc.string cimport memset
from cpython.buffer cimport PyBuffer_FillInfo

cdef class AudioMixer:

    def __cinit__(self, *args, **kwargs):
        cdef int status

        self._connected_slots = list()
        self._input_volume = 100
        self._output_volume = 100

        status = pj_mutex_create_recursive(_get_ua()._pjsip_endpoint._pool, "audio_mixer_lock", &self._lock)
        if status != 0:
            raise PJSIPError("failed to create lock", status)

    def __init__(self, unicode input_device, unicode output_device, int sample_rate, int ec_tail_length, int slot_count=254):
        global _dealloc_handler_queue
        cdef int status
        cdef pj_pool_t *conf_pool
        cdef pj_pool_t *snd_pool
        cdef pjmedia_conf **conf_bridge_address
        cdef pjmedia_port **null_port_address
        cdef bytes conf_pool_name, snd_pool_name
        cdef PJSIPUA ua

        ua = _get_ua()
        conf_bridge_address = &self._obj
        null_port_address = &self._null_port

        if self._obj != NULL:
            raise SIPCoreError("AudioMixer.__init__() was already called")
        if ec_tail_length < 0:
            raise ValueError("ec_tail_length argument cannot be negative")
        if sample_rate <= 0:
            raise ValueError("sample_rate argument should be a non-negative integer")
        if sample_rate % 50:
            raise ValueError("sample_rate argument should be dividable by 50")
        self.sample_rate = sample_rate
        self.slot_count = slot_count

        conf_pool_name = b"AudioMixer_%d" % id(self)
        conf_pool = ua.create_memory_pool(conf_pool_name, 4096, 4096)
        self._conf_pool = conf_pool
        snd_pool_name = b"AudioMixer_snd_%d" % id(self)
        snd_pool = ua.create_memory_pool(snd_pool_name, 4096, 4096)
        self._snd_pool = snd_pool
        with nogil:
            status = pjmedia_conf_create(conf_pool, slot_count+1, sample_rate, 1,
                                         sample_rate / 50, 16, PJMEDIA_CONF_NO_DEVICE, conf_bridge_address)
        if status != 0:
            raise PJSIPError("Could not create audio mixer", status)
        with nogil:
            status = pjmedia_null_port_create(conf_pool, sample_rate, 1,
                                              sample_rate / 50, 16, null_port_address)
        if status != 0:
            raise PJSIPError("Could not create null audio port", status)
        self._start_sound_device(ua, input_device, output_device, ec_tail_length)
        if not (input_device is None and output_device is None):
            self._stop_sound_device(ua)
        _add_handler(_AudioMixer_dealloc_handler, self, &_dealloc_handler_queue)

    # properties

    property input_volume:

        def __get__(self):
            return self._input_volume

        def __set__(self, int value):
            cdef int status
            cdef int volume
            cdef pj_mutex_t *lock = self._lock
            cdef pjmedia_conf *conf_bridge
            cdef PJSIPUA ua

            try:
                ua = _get_ua()
            except SIPCoreError:
                pass

            with nogil:
                status = pj_mutex_lock(lock)
            if status != 0:
                raise PJSIPError("failed to acquire lock", status)
            try:
                conf_bridge = self._obj

                if value < 0:
                    raise ValueError("input_volume attribute cannot be negative")
                if ua is not None:
                    volume = int(value * 1.28 - 128)
                    with nogil:
                        status = pjmedia_conf_adjust_rx_level(conf_bridge, 0, volume)
                    if status != 0:
                        raise PJSIPError("Could not set input volume of sound device", status)
                if value > 0 and self._muted:
                    self._muted = False
                self._input_volume = value
            finally:
                with nogil:
                    pj_mutex_unlock(lock)

    property output_volume:

        def __get__(self):
            return self._output_volume

        def __set__(self, int value):
            cdef int status
            cdef int volume
            cdef pj_mutex_t *lock = self._lock
            cdef pjmedia_conf *conf_bridge
            cdef PJSIPUA ua

            try:
                ua = _get_ua()
            except SIPCoreError:
                pass

            with nogil:
                status = pj_mutex_lock(lock)
            if status != 0:
                raise PJSIPError("failed to acquire lock", status)
            try:
                conf_bridge = self._obj

                if value < 0:
                    raise ValueError("output_volume attribute cannot be negative")
                if ua is not None:
                    volume = int(value * 1.28 - 128)
                    with nogil:
                        status = pjmedia_conf_adjust_tx_level(conf_bridge, 0, volume)
                    if status != 0:
                        raise PJSIPError("Could not set output volume of sound device", status)
                self._output_volume = value
            finally:
                with nogil:
                    pj_mutex_unlock(lock)

    property muted:

        def __get__(self):
            return self._muted

        def __set__(self, bint muted):
            cdef int status
            cdef int volume
            cdef pj_mutex_t *lock = self._lock
            cdef pjmedia_conf *conf_bridge
            cdef PJSIPUA ua

            try:
                ua = _get_ua()
            except SIPCoreError:
                pass

            with nogil:
                status = pj_mutex_lock(lock)
            if status != 0:
                raise PJSIPError("failed to acquire lock", status)
            try:
                conf_bridge = self._obj

                if muted == self._muted:
                    return
                if ua is not None:
                    if muted:
                        volume = -128
                    else:
                        volume = int(self._input_volume * 1.28 - 128)
                    with nogil:
                        status = pjmedia_conf_adjust_rx_level(conf_bridge, 0, volume)
                    if status != 0:
                        raise PJSIPError("Could not set input volume of sound device", status)
                self._muted = muted
            finally:
                with nogil:
                    pj_mutex_unlock(lock)

    property connected_slots:

        def __get__(self):
            return sorted(self._connected_slots)

    # public methods

    def set_sound_devices(self, unicode input_device, unicode output_device, int ec_tail_length):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef PJSIPUA ua

        ua = _get_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if ec_tail_length < 0:
                raise ValueError("ec_tail_length argument cannot be negative")
            self._stop_sound_device(ua)
            self._start_sound_device(ua, input_device, output_device, ec_tail_length)
            if self.used_slot_count == 0 and not (input_device is None and output_device is None):
                self._stop_sound_device(ua)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def connect_slots(self, int src_slot, int dst_slot):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef pjmedia_conf *conf_bridge
        cdef tuple connection
        cdef PJSIPUA ua

        ua = _get_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            conf_bridge = self._obj

            if src_slot < 0:
                raise ValueError("src_slot argument cannot be negative")
            if dst_slot < 0:
                raise ValueError("dst_slot argument cannot be negative")
            connection = (src_slot, dst_slot)
            if connection in self._connected_slots:
                return
            with nogil:
                status = pjmedia_conf_connect_port(conf_bridge, src_slot, dst_slot, 0)
            if status != 0:
                raise PJSIPError("Could not connect slots on audio mixer", status)
            self._connected_slots.append(connection)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def disconnect_slots(self, int src_slot, int dst_slot):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef pjmedia_conf *conf_bridge
        cdef tuple connection
        cdef PJSIPUA ua

        ua = _get_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            conf_bridge = self._obj

            if src_slot < 0:
                raise ValueError("src_slot argument cannot be negative")
            if dst_slot < 0:
                raise ValueError("dst_slot argument cannot be negative")
            connection = (src_slot, dst_slot)
            if connection not in self._connected_slots:
                return
            with nogil:
                status = pjmedia_conf_disconnect_port(conf_bridge, src_slot, dst_slot)
            if status != 0:
                raise PJSIPError("Could not disconnect slots on audio mixer", status)
            self._connected_slots.remove(connection)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def reset_ec(self):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef PJSIPUA ua

        ua = _get_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._snd == NULL:
                return
            with nogil:
                pjmedia_snd_port_reset_ec_state(self._snd)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    # private methods

    cdef void _start_sound_device(self, PJSIPUA ua, unicode input_device, unicode output_device, int ec_tail_length):
        cdef int idx
        cdef int input_device_i = -99
        cdef int output_device_i = -99
        cdef int sample_rate = self.sample_rate
        cdef int status
        cdef pj_pool_t *conf_pool
        cdef pj_pool_t *snd_pool
        cdef pjmedia_conf *conf_bridge
        cdef pjmedia_master_port **master_port_address
        cdef pjmedia_port *null_port
        cdef pjmedia_aud_dev_info dev_info
        cdef pjmedia_snd_port **snd_port_address
        cdef pjmedia_aud_param aud_param
        cdef pjmedia_snd_port_param port_param

        conf_bridge = self._obj
        conf_pool = self._conf_pool
        snd_pool = self._snd_pool
        master_port_address = &self._master_port
        null_port = self._null_port
        sample_rate = self.sample_rate
        snd_port_address = &self._snd

        with nogil:
            status = pj_rwmutex_lock_read(ua.audio_change_rwlock)
        if status != 0:
            raise PJSIPError('Audio change lock could not be acquired for read', status)

        try:
            dev_count = pjmedia_aud_dev_count()
            if dev_count == 0:
                input_device = None
                output_device = None
            if input_device == u"system_default":
                input_device_i = PJMEDIA_AUD_DEFAULT_CAPTURE_DEV
            if output_device == u"system_default":
                output_device_i = PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV
            if ((input_device_i == -99 and input_device is not None) or
                (output_device_i == -99 and output_device is not None)):
                for i in range(dev_count):
                    with nogil:
                        status = pjmedia_aud_dev_get_info(i, &dev_info)
                    if status != 0:
                        raise PJSIPError("Could not get audio device info", status)
                    if (input_device is not None and input_device_i == -99 and
                        dev_info.input_count > 0 and decode_device_name(dev_info.name) == input_device):
                        input_device_i = i
                    if (output_device is not None and output_device_i == -99 and
                        dev_info.output_count > 0 and decode_device_name(dev_info.name) == output_device):
                        output_device_i = i
                if input_device_i == -99 and input_device is not None:
                    input_device_i = PJMEDIA_AUD_DEFAULT_CAPTURE_DEV
                if output_device_i == -99 and output_device is not None:
                    output_device_i = PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV
            if input_device is None and output_device is None:
                with nogil:
                    status = pjmedia_master_port_create(conf_pool, null_port, pjmedia_conf_get_master_port(conf_bridge), 0, master_port_address)
                if status != 0:
                    raise PJSIPError("Could not create master port for dummy sound device", status)
                with nogil:
                    status = pjmedia_master_port_start(master_port_address[0])
                if status != 0:
                    raise PJSIPError("Could not start master port for dummy sound device", status)
            else:
                pjmedia_snd_port_param_default(&port_param)
                idx = input_device_i if input_device is not None else output_device_i
                with nogil:
                    status = pjmedia_aud_dev_default_param(idx, &port_param.base)
                if status != 0:
                    raise PJSIPError("Could not get default parameters for audio device", status)
                if input_device is None:
                    port_param.base.dir = PJMEDIA_DIR_PLAYBACK
                    port_param.base.play_id = output_device_i
                elif output_device is None:
                    port_param.base.dir = PJMEDIA_DIR_CAPTURE
                    port_param.base.rec_id = input_device_i
                else:
                    port_param.base.dir = PJMEDIA_DIR_CAPTURE_PLAYBACK
                    port_param.base.play_id = output_device_i
                    port_param.base.rec_id = input_device_i
                port_param.base.channel_count = 1
                port_param.base.clock_rate = sample_rate
                port_param.base.samples_per_frame = sample_rate / 50
                port_param.base.bits_per_sample = 16
                port_param.base.flags |= (PJMEDIA_AUD_DEV_CAP_EC | PJMEDIA_AUD_DEV_CAP_EC_TAIL)
                port_param.base.ec_enabled = 1
                port_param.base.ec_tail_ms = ec_tail_length
                with nogil:
                    status = pjmedia_snd_port_create2(snd_pool, &port_param, snd_port_address)
                if status == PJMEDIA_ENOSNDPLAY:
                    ua.reset_memory_pool(snd_pool)
                    self._start_sound_device(ua, input_device, None, ec_tail_length)
                    return
                elif status == PJMEDIA_ENOSNDREC:
                    ua.reset_memory_pool(snd_pool)
                    self._start_sound_device(ua, None, output_device, ec_tail_length)
                    return
                elif status != 0:
                    raise PJSIPError("Could not create sound device", status)
                with nogil:
                    status = pjmedia_snd_port_connect(snd_port_address[0], pjmedia_conf_get_master_port(conf_bridge))
                if status != 0:
                    self._stop_sound_device(ua)
                    raise PJSIPError("Could not connect sound device", status)
                if input_device_i == PJMEDIA_AUD_DEFAULT_CAPTURE_DEV or output_device_i == PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV:
                    with nogil:
                        status = pjmedia_aud_stream_get_param(pjmedia_snd_port_get_snd_stream(snd_port_address[0]), &aud_param)
                    if status != 0:
                        self._stop_sound_device(ua)
                        raise PJSIPError("Could not get sounds device info", status)
                    if input_device_i == PJMEDIA_AUD_DEFAULT_CAPTURE_DEV:
                        with nogil:
                            status = pjmedia_aud_dev_get_info(aud_param.rec_id, &dev_info)
                        if status != 0:
                            raise PJSIPError("Could not get audio device info", status)
                        self.real_input_device = decode_device_name(dev_info.name)
                    if output_device_i == PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV:
                        with nogil:
                            status = pjmedia_aud_dev_get_info(aud_param.play_id, &dev_info)
                        if status != 0:
                            raise PJSIPError("Could not get audio device info", status)
                        self.real_output_device = decode_device_name(dev_info.name)
            if input_device_i != PJMEDIA_AUD_DEFAULT_CAPTURE_DEV:
                self.real_input_device = input_device
            if output_device_i != PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV:
                self.real_output_device = output_device
            self.input_device = input_device
            self.output_device = output_device
            self.ec_tail_length = ec_tail_length
        finally:
            with nogil:
                pj_rwmutex_unlock_read(ua.audio_change_rwlock)

    cdef void _stop_sound_device(self, PJSIPUA ua):
        cdef pjmedia_master_port *master_port
        cdef pjmedia_snd_port *snd_port

        master_port = self._master_port
        snd_port = self._snd

        if self._snd != NULL:
            with nogil:
                pjmedia_snd_port_destroy(snd_port)
            self._snd = NULL
        ua.reset_memory_pool(self._snd_pool)
        if self._master_port != NULL:
            with nogil:
                pjmedia_master_port_destroy(master_port, 0)
            self._master_port = NULL

    cdef int _add_port(self, PJSIPUA ua, pj_pool_t *pool, pjmedia_port *port) except -1 with gil:
        cdef int input_device_i
        cdef int output_device_i
        cdef unsigned int slot
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef pjmedia_conf* conf_bridge

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            conf_bridge = self._obj

            with nogil:
                status = pjmedia_conf_add_port(conf_bridge, pool, port, NULL, &slot)
            if status != 0:
                raise PJSIPError("Could not add audio object to audio mixer", status)
            self.used_slot_count += 1
            if self.used_slot_count == 1 and not (self.input_device is None and self.output_device is None) and self._snd == NULL:
                self._start_sound_device(ua, self.input_device, self.output_device, self.ec_tail_length)
            return slot
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef int _remove_port(self, PJSIPUA ua, unsigned int slot) except -1 with gil:
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef pjmedia_conf* conf_bridge
        cdef tuple connection
        cdef Timer timer

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            conf_bridge = self._obj

            with nogil:
                status = pjmedia_conf_remove_port(conf_bridge, slot)
            if status != 0:
                raise PJSIPError("Could not remove audio object from audio mixer", status)
            self._connected_slots = [connection for connection in self._connected_slots if slot not in connection]
            self.used_slot_count -= 1
            if self.used_slot_count == 0 and not (self.input_device is None and self.output_device is None):
                timer = Timer()
                timer.schedule(0, <timer_callback>self._cb_postpoll_stop_sound, self)
            return 0
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef int _cb_postpoll_stop_sound(self, timer) except -1:
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef PJSIPUA ua

        ua = _get_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self.used_slot_count == 0:
                self._stop_sound_device(ua)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def __dealloc__(self):
        global _dealloc_handler_queue
        cdef PJSIPUA ua
        cdef pjmedia_conf *conf_bridge = self._obj
        cdef pjmedia_port *null_port = self._null_port

        _remove_handler(self, &_dealloc_handler_queue)

        try:
            ua = _get_ua()
        except:
            return

        self._stop_sound_device(ua)
        if self._null_port != NULL:
            with nogil:
                pjmedia_port_destroy(null_port)
            self._null_port = NULL
        if self._obj != NULL:
            with nogil:
                pjmedia_conf_destroy(conf_bridge)
            self._obj = NULL
        ua.release_memory_pool(self._conf_pool)
        self._conf_pool = NULL
        ua.release_memory_pool(self._snd_pool)
        self._snd_pool = NULL
        if self._lock != NULL:
            pj_mutex_destroy(self._lock)


cdef class ToneGenerator:
    # properties

    property volume:

        def __get__(self):
            return self._volume

        def __set__(self, value):
            cdef int slot
            cdef int volume
            cdef int status
            cdef pj_mutex_t *lock = self._lock
            cdef pjmedia_conf *conf_bridge
            cdef PJSIPUA ua

            ua = self._get_ua(0)

            if ua is not None:
                with nogil:
                    status = pj_mutex_lock(lock)
                if status != 0:
                    raise PJSIPError("failed to acquire lock", status)
            try:
                conf_bridge = self.mixer._obj
                slot = self._slot

                if value < 0:
                    raise ValueError("volume attribute cannot be negative")
                if ua is not None and self._slot != -1:
                    volume = int(value * 1.28 - 128)
                    with nogil:
                        status = pjmedia_conf_adjust_rx_level(conf_bridge, slot, volume)
                    if status != 0:
                        raise PJSIPError("Could not set volume of tone generator", status)
                self._volume = value
            finally:
                if ua is not None:
                    with nogil:
                        pj_mutex_unlock(lock)

    property slot:

        def __get__(self):
            self._get_ua(0)
            if self._slot == -1:
                return None
            else:
                return self._slot

    property is_active:

        def __get__(self):
            self._get_ua(0)
            return bool(self._slot != -1)

    property is_busy:

        def __get__(self):
            cdef int status
            cdef pj_mutex_t *lock = self._lock
            cdef pjmedia_port *port
            cdef PJSIPUA ua

            ua = self._get_ua(0)
            if ua is None:
                return False

            with nogil:
                status = pj_mutex_lock(lock)
            if status != 0:
                raise PJSIPError("failed to acquire lock", status)
            try:
                port = self._obj

                if self._obj == NULL:
                    return False
                with nogil:
                    status = pjmedia_tonegen_is_busy(port)
                return bool(status)
            finally:
                with nogil:
                    pj_mutex_unlock(lock)

    # public methods

    def __cinit__(self, *args, **kwargs):
        cdef int status
        cdef pj_pool_t *pool
        cdef bytes pool_name
        cdef PJSIPUA ua

        ua = _get_ua()

        status = pj_mutex_create_recursive(ua._pjsip_endpoint._pool, "tone_generator_lock", &self._lock)
        if status != 0:
            raise PJSIPError("failed to create lock", status)

        pool_name = b"ToneGenerator_%d" % id(self)
        pool = ua.create_memory_pool(pool_name, 4096, 4096)
        self._pool = pool
        self._slot = -1
        self._timer = None
        self._volume = 100

    def __init__(self, AudioMixer mixer):
        cdef int sample_rate
        cdef int status
        cdef pj_pool_t *pool
        cdef pjmedia_port **port_address
        cdef PJSIPUA ua

        ua = _get_ua()
        pool = self._pool
        port_address = &self._obj
        sample_rate = mixer.sample_rate

        if self._obj != NULL:
            raise SIPCoreError("ToneGenerator.__init__() was already called")
        if mixer is None:
            raise ValueError("mixer argument may not be None")
        self.mixer = mixer
        with nogil:
            status = pjmedia_tonegen_create(pool, sample_rate, 1,
                                            sample_rate / 50, 16, 0, port_address)
        if status != 0:
            raise PJSIPError("Could not create tone generator", status)

    def start(self):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef PJSIPUA ua

        ua = self._get_ua(1)

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._slot != -1:
                return
            self._slot = self.mixer._add_port(ua, self._pool, self._obj)
            if self._volume != 100:
                self.volume = self._volume
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def stop(self):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef PJSIPUA ua

        ua = self._get_ua(0)
        if ua is None:
            return

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._slot == -1:
                return
            self._stop(ua)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def __dealloc__(self):
        cdef pjmedia_port *port = self._obj
        cdef PJSIPUA ua

        ua = self._get_ua(0)
        if ua is None:
            return

        self._stop(ua)
        if self._obj != NULL:
            with nogil:
                pjmedia_tonegen_stop(port)
            self._obj = NULL
        ua.release_memory_pool(self._pool)
        self._pool = NULL
        if self._lock != NULL:
            pj_mutex_destroy(self._lock)

    def play_tones(self, object tones):
        cdef unsigned int count = 0
        cdef int duration
        cdef int freq1
        cdef int freq2
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef pjmedia_port *port
        cdef pjmedia_tone_desc tones_arr[PJMEDIA_TONEGEN_MAX_DIGITS]
        cdef PJSIPUA ua

        ua = self._get_ua(1)

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            port = self._obj

            if self._slot == -1:
                raise SIPCoreError("ToneGenerator has not yet been started")
            for freq1, freq2, duration in tones:
                if freq1 == 0 and count > 0:
                    tones_arr[count-1].off_msec += duration
                else:
                    if count >= PJMEDIA_TONEGEN_MAX_DIGITS:
                        raise SIPCoreError("Too many tones")
                    tones_arr[count].freq1 = freq1
                    tones_arr[count].freq2 = freq2
                    tones_arr[count].on_msec = duration
                    tones_arr[count].off_msec = 0
                    tones_arr[count].volume = 0
                    tones_arr[count].flags = 0
                    count += 1
            if count > 0:
                with nogil:
                    status = pjmedia_tonegen_play(port, count, tones_arr, 0)
                if status != 0 and status != PJ_ETOOMANY:
                    raise PJSIPError("Could not playback tones", status)
            if self._timer is None:
                self._timer = Timer()
                self._timer.schedule(0.250, <timer_callback>self._cb_check_done, self)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def play_dtmf(self, str digit):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef pjmedia_port *port
        cdef pjmedia_tone_digit tone
        cdef PJSIPUA ua

        ua = self._get_ua(1)

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            port = self._obj

            if self._slot == -1:
                raise SIPCoreError("ToneGenerator has not yet been started")
            tone.digit = ord(digit)
            tone.on_msec = 200
            tone.off_msec = 50
            tone.volume = 0
            with nogil:
                status = pjmedia_tonegen_play_digits(port, 1, &tone, 0)
            if status != 0 and status != PJ_ETOOMANY:
                raise PJSIPError("Could not playback DTMF tone", status)
            if self._timer is None:
                self._timer = Timer()
                self._timer.schedule(0.250, <timer_callback>self._cb_check_done, self)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    # private methods

    cdef PJSIPUA _get_ua(self, int raise_exception):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except SIPCoreError:
            self._obj = NULL
            self._pool = NULL
            self._slot = -1
            self._timer = None
            if raise_exception:
                raise
            else:
                return None
        else:
            return ua

    cdef int _stop(self, PJSIPUA ua) except -1:
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None
        if self._slot != -1:
            self.mixer._remove_port(ua, self._slot)
            self._slot = -1
        return 0

    cdef int _cb_check_done(self, timer) except -1:
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef pjmedia_port *port

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            port = self._obj

            with nogil:
                status = pjmedia_tonegen_is_busy(port)
            if status:
                self._timer = Timer()
                self._timer.schedule(0.250, <timer_callback>self._cb_check_done, self)
            else:
                self._timer = None
                _add_event("ToneGeneratorDidFinishPlaying", dict(obj=self))
        finally:
            with nogil:
                pj_mutex_unlock(lock)


cdef class RecordingWaveFile:
    def __cinit__(self, *args, **kwargs):
        cdef int status

        status = pj_mutex_create_recursive(_get_ua()._pjsip_endpoint._pool, "recording_wave_file_lock", &self._lock)
        if status != 0:
            raise PJSIPError("failed to create lock", status)

        self._slot = -1

    def __init__(self, AudioMixer mixer, filename):
        if self.filename is not None:
            raise SIPCoreError("RecordingWaveFile.__init__() was already called")
        if mixer is None:
            raise ValueError("mixer argument may not be None")
        if filename is None:
            raise ValueError("filename argument may not be None")
        if not isinstance(filename, basestring):
            raise TypeError("file argument must be str or unicode")
        if isinstance(filename, unicode):
            filename = filename.encode(sys.getfilesystemencoding())
        self.mixer = mixer
        self.filename = filename

    cdef PJSIPUA _check_ua(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
            return ua
        except:
            self._pool = NULL
            self._port = NULL
            self._slot = -1
            return None

    property is_active:

        def __get__(self):
            self._check_ua()
            return self._slot != -1

    property slot:

        def __get__(self):
            self._check_ua()
            if self._slot == -1:
                return None
            else:
                return self._slot

    def start(self):
        cdef char *filename
        cdef int sample_rate
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef pj_pool_t *pool
        cdef pjmedia_port **port_address
        cdef bytes pool_name
        cdef char* c_pool_name
        cdef PJSIPUA ua

        ua = _get_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            filename = PyString_AsString(self.filename)
            pool_name = b"RecordingWaveFile_%d" % id(self)
            port_address = &self._port
            sample_rate = self.mixer.sample_rate

            if self._was_started:
                raise SIPCoreError("This RecordingWaveFile was already started once")
            pool = ua.create_memory_pool(pool_name, 4096, 4096)
            self._pool = pool
            try:
                with nogil:
                    status = pjmedia_wav_writer_port_create(pool, filename,
                                                            sample_rate, 1,
                                                            sample_rate / 50, 16,
                                                            PJMEDIA_FILE_WRITE_PCM, 0, port_address)
                if status != 0:
                    raise PJSIPError("Could not create WAV file", status)
                self._slot = self.mixer._add_port(ua, self._pool, self._port)
            except:
                self.stop()
                raise
            self._was_started = 1
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def stop(self):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef PJSIPUA ua

        ua = self._check_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            self._stop(ua)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef int _stop(self, PJSIPUA ua) except -1:
        cdef pjmedia_port *port = self._port

        if self._slot != -1:
            self.mixer._remove_port(ua, self._slot)
            self._slot = -1
        if self._port != NULL:
            with nogil:
                pjmedia_port_destroy(port)
            self._port = NULL
        ua.release_memory_pool(self._pool)
        self._pool = NULL
        return 0

    def __dealloc__(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except:
            return
        self._stop(ua)

        if self._lock != NULL:
            pj_mutex_destroy(self._lock)


cdef class WaveFile:
    def __cinit__(self, *args, **kwargs):
        cdef int status

        self.weakref = weakref.ref(self)
        Py_INCREF(self.weakref)

        status = pj_mutex_create_recursive(_get_ua()._pjsip_endpoint._pool, "wave_file_lock", &self._lock)
        if status != 0:
            raise PJSIPError("failed to create lock", status)

        self._slot = -1
        self._volume = 100

    def __init__(self, AudioMixer mixer, filename):
        if self.filename is not None:
            raise SIPCoreError("WaveFile.__init__() was already called")
        if mixer is None:
            raise ValueError("mixer argument may not be None")
        if filename is None:
            raise ValueError("filename argument may not be None")
        if not isinstance(filename, basestring):
            raise TypeError("file argument must be str or unicode")
        if isinstance(filename, unicode):
            filename = filename.encode(sys.getfilesystemencoding())
        self.mixer = mixer
        self.filename = filename

    cdef PJSIPUA _check_ua(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
            return ua
        except:
            self._pool = NULL
            self._port = NULL
            self._slot = -1
            return None

    property is_active:

        def __get__(self):
            self._check_ua()
            return self._port != NULL

    property slot:

        def __get__(self):
            self._check_ua()
            if self._slot == -1:
                return None
            else:
                return self._slot

    property volume:

        def __get__(self):
            return self._volume

        def __set__(self, value):
            cdef int slot
            cdef int status
            cdef int volume
            cdef pj_mutex_t *lock = self._lock
            cdef pjmedia_conf *conf_bridge
            cdef PJSIPUA ua

            ua = self._check_ua()

            if ua is not None:
                with nogil:
                    status = pj_mutex_lock(lock)
                if status != 0:
                    raise PJSIPError("failed to acquire lock", status)
            try:
                conf_bridge = self.mixer._obj
                slot = self._slot

                if value < 0:
                    raise ValueError("volume attribute cannot be negative")
                if ua is not None and self._slot != -1:
                    volume = int(value * 1.28 - 128)
                    with nogil:
                        status = pjmedia_conf_adjust_rx_level(conf_bridge, slot, volume)
                    if status != 0:
                        raise PJSIPError("Could not set volume of .wav file", status)
                self._volume = value
            finally:
                if ua is not None:
                    with nogil:
                        pj_mutex_unlock(lock)

    def start(self):
        cdef char *filename
        cdef int status
        cdef void *weakref
        cdef pj_pool_t *pool
        cdef pj_mutex_t *lock = self._lock
        cdef pjmedia_port **port_address
        cdef bytes pool_name
        cdef char* c_pool_name
        cdef PJSIPUA ua

        ua = _get_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            filename = PyString_AsString(self.filename)
            port_address = &self._port
            weakref = <void *> self.weakref

            if self._port != NULL:
                raise SIPCoreError("WAV file is already playing")
            pool_name = b"WaveFile_%d" % id(self)
            pool = ua.create_memory_pool(pool_name, 4096, 4096)
            self._pool = pool
            try:
                with nogil:
                    status = pjmedia_wav_player_port_create(pool, filename, 0, PJMEDIA_FILE_NO_LOOP, 0, port_address)
                if status != 0:
                    raise PJSIPError("Could not open WAV file", status)
                with nogil:
                    status = pjmedia_wav_player_set_eof_cb(port_address[0], weakref, cb_play_wav_eof)
                if status != 0:
                    raise PJSIPError("Could not set WAV EOF callback", status)
                self._slot = self.mixer._add_port(ua, self._pool, self._port)
                if self._volume != 100:
                    self.volume = self._volume
            except:
                self._stop(ua, 0)
                raise
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef int _stop(self, PJSIPUA ua, int notify) except -1:
        cdef int status
        cdef int was_active
        cdef pj_pool_t *pool
        cdef pjmedia_port *port

        port = self._port
        was_active = 0

        if self._slot != -1:
            was_active = 1
            self.mixer._remove_port(ua, self._slot)
            self._slot = -1
        if self._port != NULL:
            with nogil:
                pjmedia_port_destroy(port)
            self._port = NULL
            was_active = 1
        ua.release_memory_pool(self._pool)
        self._pool = NULL
        if notify and was_active:
            _add_event("WaveFileDidFinishPlaying", dict(obj=self))

    def stop(self):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef PJSIPUA ua

        ua = self._check_ua()
        if ua is None:
            return

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            self._stop(ua, 1)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def __dealloc__(self):
        cdef PJSIPUA ua
        cdef Timer timer
        try:
            ua = _get_ua()
        except:
            return
        self._stop(ua, 0)
        timer = Timer()
        try:
            timer.schedule(60, deallocate_weakref, self.weakref)
        except SIPCoreError:
            pass
        if self._lock != NULL:
            pj_mutex_destroy(self._lock)

    cdef int _cb_eof(self, timer) except -1:
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef PJSIPUA ua

        ua = self._check_ua()
        if ua is None:
            return 0

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            self._stop(ua, 1)
        finally:
            with nogil:
                pj_mutex_unlock(lock)


cdef class MixerPort:
    def __cinit__(self, *args, **kwargs):
        cdef int status

        status = pj_mutex_create_recursive(_get_ua()._pjsip_endpoint._pool, "mixer_port_lock", &self._lock)
        if status != 0:
            raise PJSIPError("failed to create lock", status)

        self._slot = -1

    def __init__(self, AudioMixer mixer):
        if self.mixer is not None:
            raise SIPCoreError("MixerPort.__init__() was already called")
        if mixer is None:
            raise ValueError("mixer argument may not be None")
        self.mixer = mixer

    cdef PJSIPUA _check_ua(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
            return ua
        except:
            self._pool = NULL
            self._port = NULL
            self._slot = -1
            return None

    property is_active:

        def __get__(self):
            self._check_ua()
            return self._slot != -1

    property slot:

        def __get__(self):
            self._check_ua()
            if self._slot == -1:
                return None
            else:
                return self._slot

    def start(self):
        cdef int sample_rate
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef pj_pool_t *pool
        cdef pjmedia_port **port_address
        cdef bytes pool_name
        cdef PJSIPUA ua

        ua = _get_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            pool_name = b"MixerPort_%d" % id(self)
            port_address = &self._port
            sample_rate = self.mixer.sample_rate

            if self._was_started:
                raise SIPCoreError("This MixerPort was already started once")
            pool = ua.create_memory_pool(pool_name, 4096, 4096)
            self._pool = pool
            try:
                with nogil:
                    status = pjmedia_mixer_port_create(pool, sample_rate, 1, sample_rate / 50, 16, port_address)
                if status != 0:
                    raise PJSIPError("Could not create WAV file", status)
                self._slot = self.mixer._add_port(ua, self._pool, self._port)
            except:
                self.stop()
                raise
            self._was_started = 1
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def stop(self):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef PJSIPUA ua

        ua = self._check_ua()
        if ua is None:
            return

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            self._stop(ua)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef int _stop(self, PJSIPUA ua) except -1:
        cdef pj_pool_t *pool
        cdef pjmedia_port *port

        pool = self._pool
        port = self._port

        if self._slot != -1:
            self.mixer._remove_port(ua, self._slot)
            self._slot = -1
        if self._port != NULL:
            with nogil:
                pjmedia_port_destroy(port)
            self._port = NULL
        ua.release_memory_pool(self._pool)
        self._pool = NULL
        return 0

    def __dealloc__(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except:
            return
        self._stop(ua)
        if self._lock != NULL:
            pj_mutex_destroy(self._lock)


# callback functions

cdef int _AudioMixer_dealloc_handler(object obj) except -1:
    cdef int status
    cdef AudioMixer mixer = obj
    cdef PJSIPUA ua

    ua = _get_ua()

    status = pj_mutex_lock(mixer._lock)
    if status != 0:
        raise PJSIPError("failed to acquire lock", status)
    try:
        mixer._stop_sound_device(ua)
        mixer._connected_slots = list()
        mixer.used_slot_count = 0
    finally:
        pj_mutex_unlock(mixer._lock)

cdef int cb_play_wav_eof(pjmedia_port *port, void *user_data) with gil:
    cdef Timer timer
    cdef WaveFile wav_file

    wav_file = (<object> user_data)()
    if wav_file is not None:
        timer = Timer()
        timer.schedule(0, <timer_callback>wav_file._cb_eof, wav_file)
    # do not return PJ_SUCCESS because if you do pjsip will access the just deallocated port
    return 1

# from https://stackoverflow.com/questions/28160359/how-to-wrap-a-c-pointer-and-length-in-a-new-style-buffer-object-in-cython
cdef class MemBuf:
    def __getbuffer__(self, Py_buffer *view, int flags):
        PyBuffer_FillInfo(view, self, <void *>self.p, self.l, 1, flags)

    def __releasebuffer__(self, Py_buffer *view):
        pass

    def __dealloc__(self):
        pass

# Call this instead of constructing a MemBuf directly.  The __cinit__
# and __init__ methods can only take Python objects, so the real
# constructor is here.  See:
# https://mail.python.org/pipermail/cython-devel/2012-June/002734.html
cdef MemBuf MemBuf_init(const void *p, size_t l) with gil:
    cdef MemBuf ret = MemBuf()
    ret.p = p
    ret.l = l
    return ret


# in case the below has problems follow this
# https://groups.google.com/forum/#!topic/cython-users/bP-2SxAwuNk

cdef int TTYDemodulatorCallback(void* p_obl, int event, int data) with gil:
    cdef OBL * obl = <OBL *>p_obl
    cdef void * user_data = obl.user_data
    cdef object ttyDemodObj
    cdef char c_data
    if user_data != NULL:
        c_data = <char>data
        if event == OBL_EVENT_DEMOD_CHAR:
            ttyDemodObj = <object>user_data
            ttyDemodObj.on_callback(<object>c_data)
    return 0

cdef int mem_capture_got_data(pjmedia_port *port, void *usr_data) with gil:
    cdef object myObj = <object>usr_data
    if myObj is not None:
        try:
            myObj.process_data()
        except:
            pass
    return 0

cdef int wave_tty_test_callback(void* p_obl, int event, int data) with gil:
    cdef f
    cdef p_data
    if event == OBL_EVENT_DEMOD_CHAR:
        p_data = <object>data
        f = open("/root/sipsimple.log", "a+")
        f.write(p_data)
        f.write("\n")
        f.close()

cdef void wave_tty_test():
    cdef OBL obl
    cdef char c_byte1
    cdef char c_byte2
    cdef f
    cdef byte1
    cdef byte2

    obl_init(&obl, OBL_BAUD_45, wave_tty_test_callback)
    f = open("/usr/local/py-psap/psap-webrtc/22db937277674dfeb208c04adfc6f01b.raw", "rb")
    try:
            byte1 = f.read(1)
            byte2 = f.read(1)
            while byte1:
                c_byte1 = <char>byte1
                c_byte2 = <char>byte2
                obl_demodulate_packet(&obl, c_byte1, c_byte2)
                byte1 = f.read(1)
                if byte1:
                        byte2 = f.read(1)
    finally:
            f.close()


cdef class TTYDemodulator:
    def __cinit__(self, *args, **kwargs):
        cdef int status

        status = pj_mutex_create_recursive(_get_ua()._pjsip_endpoint._pool, "tty_demod_lock", &self._lock)
        if status != 0:
            raise PJSIPError("failed to create lock", status)

        self._slot = -1
        obl_init(&self.obl, OBL_BAUD_45, TTYDemodulatorCallback)
        init_check_for_tty(&self.obl_tty_detect)
        self.obl.user_data = <void *>self

    def __init__(self, AudioMixer mixer, room_number, callback_func, trace_func):
        if mixer is None:
            raise ValueError("mixer argument may not be None")
        if callback_func is None:
            raise ValueError("callback_func argument may not be None")
        self.mixer = mixer
        self.callback_func = callback_func
        self.output_file = open("{}.raw".format(room_number),"wb")
        self.trace = trace_func
        self.trace("tty __init__")
        self.tty_enabled = False

    cdef PJSIPUA _check_ua(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
            return ua
        except:
            self._pool = NULL
            self._port = NULL
            self._slot = -1
            return None

    property is_active:

        def __get__(self):
            self._check_ua()
            return self._slot != -1

    property slot:

        def __get__(self):
            self._check_ua()
            if self._slot == -1:
                return None
            else:
                return self._slot

    def on_callback(self, c_data):
        self.trace("inside on_callback")
        self.trace("inside on_callback for {}".format(c_data))
        self.callback_func(c_data)

    def process_data(self):
        cdef int num_bytes
        cdef int num_samples
        cdef object pyBuf
        cdef object n
        cdef int count
        cdef char byte1
        cdef char byte2
        cdef int tty_detect
        count = 0
        num_bytes = pjmedia_mem_capture_get_size(self._port)
        if num_bytes > 0:
            #self.trace("num_bytes - start")
            #num_samples = num_bytes/2
            # todo - this might be buggy, need to check and fix
            n = <object>num_bytes
            #self.trace("{} num  bytes".format(n))
            while count < num_bytes:
                if self.tty_enabled:
                    obl_demodulate_packet(&self.obl, self.buffer[count], self.buffer[count+1])
                else:
                    tty_detect = check_for_tty(&self.obl_tty_detect, self.buffer[count], self.buffer[count+1])
                    if tty_detect == 1:
                        self.tty_enabled = True
                count = count + 2
            #data = <short *>self.buffer
            #obl_demodulate(&self.obl, data, num_samples)
            #pyBuf = MemBuf_init(self.buffer, num_bytes)
            #self.output_file.write(pyBuf)
            #self.trace("num_bytes {}".format(n))

    def test(self):
        wave_tty_test()

    def start(self):
        cdef int sample_rate
        cdef object o_sample_rate
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef pj_pool_t *pool
        cdef pjmedia_port **port_address
        cdef bytes pool_name
        cdef char* c_pool_name
        cdef PJSIPUA ua
        cdef void * user_data = <void *>self
        cdef myObj = <object>user_data
        ua = _get_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            pool_name = b"TTYDemod_%d" % id(self)
            port_address = &self._port
            sample_rate = self.mixer.sample_rate
            o_sample_rate = <object>sample_rate
            self.trace("sample rate {}".format(o_sample_rate))

            if self._was_started:
                raise SIPCoreError("This TTYDemodulator was already started once")
            pool = ua.create_memory_pool(pool_name, 4096, 4096)
            self._pool = pool
            try:
                with nogil:
                    status = pjmedia_mem_capture_create	(pool,
                                        self.buffer, 2048,
                                        sample_rate, 1,
                                        sample_rate / 50, 16,
                                        0,
                                        port_address )

                if status != 0:
                    raise PJSIPError("Could not create mem capture buffer", status)

                #with nogil:
                status = pjmedia_mem_capture_set_eof_cb	(self._port,
                                        user_data,
                                        mem_capture_got_data)

                if status != 0:
                    raise PJSIPError("Could not create mem capture cb", status)

                self._slot = self.mixer._add_port(ua, self._pool, self._port)
            except:
                self.stop()
                raise
            self._was_started = 1
        finally:
            with nogil:
                pj_mutex_unlock(lock)


    cdef int get_data_from_mem(self):
        self.trace("inside get_data_from_mem")
        self.trace("inside get_data_from_mem 1")
        return 0
        '''
        cdef size_t num_bytes
        cdef int num_samples
        cdef short * data
        with nogil:
            num_bytes = pjmedia_mem_capture_get_size(self._port)
            # assuming 2 bytes per sample
            num_samples = num_bytes/2
            # todo - this might be buggy, need to check and fix
            #data = <short *>self.buffer
            #obl_demodulate(&self.obl, data, num_samples)
        pyBuf = MemBuf_init(self.buffer, num_bytes)
        self.output_file.write(pyBuf)
        return 0
        '''


    def stop(self):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef PJSIPUA ua

        self.trace("tty stop 1")
        ua = self._check_ua()
        self.trace("tty stop 2")

        with nogil:
            status = pj_mutex_lock(lock)
        self.trace("tty stop 3")
        if status != 0:
            self.trace("tty stop 4")
            raise PJSIPError("failed to acquire lock", status)
        self.trace("tty stop 5")
        try:
            self._stop(ua)
        finally:
            with nogil:
                pj_mutex_unlock(lock)
        self.trace("tty stop 6")
        self.output_file.close()
        self.trace("tty stop 7")

    cdef int _stop(self, PJSIPUA ua) except -1:
        self.trace("tty _stop 1")
        cdef pjmedia_port *port = self._port
        self.trace("tty _stop 2")

        if self._slot != -1:
            self.trace("tty _stop 3")
            self.mixer._remove_port(ua, self._slot)
            self.trace("tty _stop 4")
            self._slot = -1
        if self._port != NULL:
            self.trace("tty _stop 5")
            with nogil:
                pjmedia_port_destroy(port)
            self._port = NULL
        self.trace("tty _stop 6")
        ua.release_memory_pool(self._pool)
        self.trace("tty _stop 7")
        self._pool = NULL
        return 0

    def __dealloc__(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except:
            return
        self._stop(ua)

        if self._lock != NULL:
            pj_mutex_destroy(self._lock)

cdef int TTYMmodulatorPlayerCallback(pjmedia_port *port, void *usr_data) with gil:
    #cdef object traceFile
    cdef object modulatorObj = <object>usr_data

    #traceFile = open('/root/sipsimple.log', 'a+')
    #traceFile.write('inside TTYMmodulatorPlayerCallback')
    #traceFile.write("\n")
    #traceFile.close()

    if modulatorObj is not None:
        modulatorObj.player_needs_more_data()
    return 0

cdef class TTYModulator:
    def __cinit__(self, *args, **kwargs):
        cdef int status

        status = pj_mutex_create_recursive(_get_ua()._pjsip_endpoint._pool, "tty_mod_lock", &self._lock)
        if status != 0:
            raise PJSIPError("failed to create lock", status)

        self._slot = -1
        # the callback here should never be called as we are modulating
        obl_init(&self.obl, OBL_BAUD_45, TTYDemodulatorCallback)
        self.buffer = malloc(2*8000*5)
        memset(self.buffer, 2*8000*5, 0)
        self.obl.user_data = NULL
        obl_set_tx_freq(&self.obl, 1358, 1728)

    def __init__(self, AudioMixer mixer, trace_func):
        if mixer is None:
            raise ValueError("mixer argument may not be None")
        self.mixer = mixer
        self.trace = trace_func
        self.bytesToSend = []
        self.trace("TTYModulator __init__")

    cdef PJSIPUA _check_ua(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
            return ua
        except:
            self._pool = NULL
            self._port = NULL
            self._slot = -1
            return None

    property is_active:

        def __get__(self):
            self._check_ua()
            return self._slot != -1

    property slot:

        def __get__(self):
            self._check_ua()
            if self._slot == -1:
                return None
            else:
                return self._slot

    def start(self):
        cdef int sample_rate
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef pj_pool_t *pool
        cdef pjmedia_port **port_address
        cdef bytes pool_name
        cdef char* c_pool_name
        cdef PJSIPUA ua

        self.trace("_core TTYModulator start")
        ua = _get_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            pool_name = b"TTYMod_%d" % id(self)
            port_address = &self._port
            sample_rate = self.mixer.sample_rate

            if self._was_started:
                raise SIPCoreError("This TTYModulator was already started once")
            pool = ua.create_memory_pool(pool_name, 4096, 4096)
            self._pool = pool
            try:
                with nogil:
                    status = pjmedia_mem_player_create(pool,
                                                        self.buffer, 2*8000*5,
                                                        sample_rate, 1,
                                                        sample_rate / 50, 16,
                                                        0,
                                                        port_address)
                if status != 0:
                    raise PJSIPError("Could not create mem player", status)
                self.trace("_core TTYModulator pjmedia_mem_player_create success")

                with nogil:
                    status = pjmedia_mem_player_set_eof_cb(self._port,
                                                            <void *>self,
                                                            TTYMmodulatorPlayerCallback)
                if status != 0:
                    raise PJSIPError("Could not create mem player", status)
                self.trace("_core TTYModulator pjmedia_mem_player_set_eof_cb success")
                self._slot = self.mixer._add_port(ua, self._pool, self._port)
                if self._slot == -1:
                    self.trace("bad ttymodulator slot")
                else:
                    self.trace("good ttymodulator slot")
            except:
                self.trace("ttymodulator start got exception")
                self.stop()
                raise
            self._was_started = 1
        finally:
            with nogil:
                pj_mutex_unlock(lock)
        self.trace("_core TTYModulator start done")

    def player_needs_more_data(self):
        cdef char ch
        cdef int i
        cdef char *cbuffer
        #self.trace("player_needs_more_data ")
        memset(self.buffer, 2*8000*5, 0)
        if len(self.bytesToSend) > 0:
            i = 0
            cbuffer = <char *>self.buffer
            self.trace("player_needs_more_data bytes is {}".format(len(self.bytesToSend)))
            while i<2*8000*5 and len(self.bytesToSend) > 0:
                ch = <char>self.bytesToSend.pop(0)
                cbuffer[i] = ch
                i = i + 1
            self.trace("player_needs_more_data done left is {}".format(len(self.bytesToSend)))

    def send_text(self, char * text):
        cdef short buffer[2050]
        cdef int n = 1
        cdef short packet
        cdef char * cData
        cdef char byte1, byte2

        self.trace("_core TTYModulator send_text {}".format(text))
        obl_tx_queue(&self.obl, text)

        data = ''
        while n > 0:
            memset(buffer, sizeof(buffer), 0)
            n = obl_modulate(&self.obl, buffer, 1024)
            self.trace("obl_modulate returned {}".format(n))
            if n > 0:
                for i in range(n):
                    packet = buffer[i]
                    cData = <char *>&packet
                    byte1 = cData[0]
                    byte2 = cData[1]
                    self.bytesToSend.append(<object>byte1)
                    self.bytesToSend.append(<object>byte2)
                #this->sampleGenerated(byte1, byte2)
            # this->samplesGenerated(buffer, n)
        self.finished_modulation(data)
        #self.trace("_core TTYModulator send_text {} done".format(text))

    def finished_modulation(self, data):
        # we send the data in our mem buffer playback
        # nothing to do here
        self.trace("finished modulation, bytes to send is {}".format(len(self.bytesToSend)))

    def stop(self):
        cdef int status
        cdef pj_mutex_t *lock = self._lock
        cdef PJSIPUA ua

        self.trace("_core TTYModulator stop")
        ua = self._check_ua()

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            self._stop(ua)
        finally:
            with nogil:
                pj_mutex_unlock(lock)
        self.trace("_core TTYModulator stop done")

    cdef int _stop(self, PJSIPUA ua) except -1:
        self.trace("_core TTYModulator _stop")
        cdef pjmedia_port *port = self._port

        if self._slot != -1:
            self.mixer._remove_port(ua, self._slot)
            self._slot = -1
        if self._port != NULL:
            with nogil:
                pjmedia_port_destroy(port)
            self._port = NULL
        ua.release_memory_pool(self._pool)
        self._pool = NULL
        self.trace("_core TTYModulator _stop done")
        return 0

    def __dealloc__(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except:
            return
        self._stop(ua)
        oblObj = <object>&self.obl
        free(self.buffer)

        if self._lock != NULL:
            pj_mutex_destroy(self._lock)
