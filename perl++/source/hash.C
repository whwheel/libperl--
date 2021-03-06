#include "internal.h"
#include <perl++/perl++.h>

namespace perl {
	namespace {
		HV* copy_to(HV* to, interpreter* interp, HV* from) {
			hv_iterinit(from);
			while (HE* iterator = hv_iternext(from)) {
				if (HeKLEN(iterator) == HEf_SVKEY) {
					hv_store_ent(to, SvREFCNT_inc(HeSVKEY(iterator)), newSVsv(HeVAL(iterator)), HeHASH(iterator));
				} 
				else {
					STRLEN len;
					char* tmp = HePV(iterator, len);
					hv_store(to, tmp, len, newSVsv(HeVAL(iterator)), HeHASH(iterator));
				}
			}
			return to;
		}
	}
	/*
	 * Class Hash::Value
	 */
	Hash::Value::Value(interpreter* _interp, HV* _handle) : interp(_interp), handle(_handle) {
	}
	Hash::Value& Hash::Value::operator=(const Hash::Value& other) {
		if (handle != other.handle) {
			clear();
			copy_to(handle, interp, other.handle);
		}
		return *this;
	}

	const Scalar::Temp Hash::Value::operator[](const Raw_string index) const {
		SV* const * const ret = hv_fetch(handle, index.value, index.length, false);
		if (!ret) {
			return Scalar::Temp(interp, newSV(0), true);
		}
		SvGETMAGIC(*ret);
		return Scalar::Temp(interp, *ret, false);
	}

	namespace {
		int string_store(pTHX_ SV* var, MAGIC* magic) {
			SV* tmp = newSVsv(var);
			hv_store(reinterpret_cast<HV*>(magic->mg_obj), magic->mg_ptr, magic->mg_len, tmp, 0);
			SvSETMAGIC(tmp);
			return 0;
		}
		MGVTBL string_magic = { 0, string_store, 0, 0, 0 MAGIC_TAIL };
	}
	Scalar::Temp Hash::Value::operator[](const Raw_string index) {
		SV* const * const ret = hv_fetch(handle, index.value, index.length, false);
		if (!ret) {
			SV* magical = newSV(0);
			sv_magicext(magical, reinterpret_cast<SV*>(handle), PERL_MAGIC_uvar, &string_magic, index.value, index.length);
			return Scalar::Temp(interp, magical, true, false);
		}
		SvGETMAGIC(*ret);
		return Scalar::Temp(interp, *ret, false);
	}


	const Scalar::Temp Hash::Value::operator[](const Scalar::Base& key) const {
		HE* const entry = hv_fetch_ent(handle, key.get_SV(true), false, 0);
		if (!entry) {
			return Scalar::Temp(interp, newSV(0), true);
		}
		SV* const ret = HeVAL(entry);
		SvGETMAGIC(ret);
		return Scalar::Temp(interp, ret, false);
	}
	namespace {
		int scalar_store(pTHX_ SV* var, MAGIC* magic) {
			SV* tmp = newSVsv(var);
			hv_store_ent(reinterpret_cast<HV*>(magic->mg_obj), *reinterpret_cast<SV**>(magic->mg_ptr), tmp, 0);
			SvSETMAGIC(tmp);
			return 0;
		}
		MGVTBL scalar_magic = { 0, scalar_store, 0, 0, 0 MAGIC_TAIL };
	}
	Scalar::Temp Hash::Value::operator[](const Scalar::Base& key) {
		HE* const entry = hv_fetch_ent(handle, key.get_SV(true), false, 0);
		if (!entry) {
			SV* magical = newSV(0);
			SV* saved = key.get_SV(false);
			sv_magicext(magical, reinterpret_cast<SV*>(handle), PERL_MAGIC_uvar, &scalar_magic, reinterpret_cast<const char*>(&saved), sizeof saved);
			return Scalar::Temp(interp, magical, true, false);
		}
		SV* const ret = HeVAL(entry);
		SvGETMAGIC(ret);
		return Scalar::Temp(interp, ret, false);
	}
	
	void Hash::Value::insert(Raw_string key, const Scalar::Base& value) {
		SV* tmp = newSVsv(value.get_SV(true));
		if (hv_store(handle, key.value, key.length, tmp, 0) == NULL) {
			SvREFCNT_dec(tmp);
			throw Runtime_exception("Couldn't save value in hash");
		}
	}
	void Hash::Value::insert(const Scalar::Base& key, const Scalar::Base& value) {
		SV* tmp = newSVsv(value.get_SV(true));
		if (hv_store_ent(handle, key.get_SV(true), tmp, 0) == NULL) {
			SvREFCNT_dec(tmp);
			throw Runtime_exception("Couldn't save value in hash");
		}
	}

	const Array::Temp Hash::Value::keys() const {
		Array::Temp ret(interp);
		foreach_init();
		while (const Iterator pair = next_value()) {
			ret.push(pair.key().as_scalar());
		}
		return ret;
	}
	const Array::Temp Hash::Value::values() const {
		Array::Temp ret(interp);
		foreach_init();
		while (const Iterator pair = next_value()) {
			ret.push(pair.value());
		}
		return ret;
	}

	unsigned Hash::Value::length() const {
		unsigned count = 0;
		foreach_init();
		while (const Iterator pair = next_value()) {
			count++;
		}
		return count;
	}

	bool Hash::Value::exists(Raw_string index) const {
		return hv_exists(handle, index.value, index.length);
	}

	bool Hash::Value::exists(const Scalar::Base& index) const {
		return hv_exists_ent(handle, index.get_SV(true), 0);
	}

	const Scalar::Temp Hash::Value::erase(Raw_string index) {
		SAVETMPS;
		SV* tmp = hv_delete(handle, index.value, index.length, 0);
		tmp = tmp ? SvREFCNT_inc(tmp) : newSV(0);
		FREETMPS;
		return Scalar::Temp(interp, tmp, true);
	}
	const Scalar::Temp Hash::Value::erase(const Scalar::Base& index) {
		SAVETMPS;
		SV* tmp = hv_delete_ent(handle, index.get_SV(true), 0, 0);
		tmp = tmp ? SvREFCNT_inc(tmp) : newSV(0);
		FREETMPS;
		return Scalar::Temp(interp, tmp, true);
	}
	void Hash::Value::clear() {
		hv_clear(handle);
	}

	void Hash::Value::undefine() {
		hv_undef(handle);
	}

	const Scalar::Temp Hash::Value::scalar() const {
		return Scalar::Temp(interp, hv_scalar(handle), false);
	}

	void Hash::Value::tie_to(const Scalar::Base& tier) {
		sv_magic(reinterpret_cast<SV*>(handle), tier.get_SV(false), PERL_MAGIC_tied, "", 0);
	}
	void Hash::Value::untie() {
		if (MAGIC* mg = SvRMAGICAL(reinterpret_cast<SV*>(handle)) ? mg_find(reinterpret_cast<SV*>(handle), PERL_MAGIC_tied) : NULL) {
			Ref<Any> tier(Ref<Any>::Temp(interp, SvREFCNT_inc(mg->mg_obj), true));
			if (tier.can("UNTIE")) {
				tier.call("UNTIE", SvREFCNT(SvRV(tier.get_SV(false))));
			}
		}
		sv_unmagic(reinterpret_cast<SV*>(handle), PERL_MAGIC_tied);
	}
	const Scalar::Temp Hash::Value::tied() const {
		if (MAGIC* mg = SvRMAGICAL(reinterpret_cast<SV*>(handle)) ? mg_find(reinterpret_cast<SV*>(handle), PERL_MAGIC_tied) : NULL) {
			return (mg->mg_obj != NULL) ?  Scalar::Temp(interp, SvREFCNT_inc(mg->mg_obj), true) : Scalar::Temp(take_ref());
		}
		return Scalar::Temp(interp, newSV(0), true);
	}

	void Hash::Value::foreach_init() const {
		hv_iterinit(handle);
	}

	const Hash::Iterator Hash::Value::next_value() const {
		return Iterator(interp, hv_iternext(handle));
	}
	Hash::Iterator Hash::Value::next_value() {
		return Iterator(interp, hv_iternext(handle));
	}

	const std::string& Hash::Value::cast_error() {
		static const std::string message("Not a hash");
		return message;
	}

	/*
	 * Class Hash::Iterator
	 */

	Hash::Iterator::Iterator(interpreter* _interp, HE* iter) : interp(_interp), iterator(iter) {
	}
	const Hash::Iterator::Key_type Hash::Iterator::key() const {
		return Key_type(*this);
	}
	const Scalar::Temp Hash::Iterator::value() const {
		SV* const ret = HeVAL(iterator);
		SvGETMAGIC(ret);
		return Scalar::Temp(interp, ret, false);
	}
	Scalar::Temp Hash::Iterator::value() {
		return Scalar::Temp(interp, HeVAL(iterator), false);
	}
	Hash::Iterator::operator bool() const {
		return iterator != NULL;
	}
	uint32_t Hash::Iterator::hashcode() const {
		return HeHASH(iterator);
	}

	/*
	 * Class Hash::Iterator::Key_type
	 */
	Hash::Iterator::Key_type::Key_type(const Hash::Iterator& _ref) : ref(_ref) {
	}

	Hash::Iterator::Key_type::operator const Raw_string() const {
		return as_raw_string();
	}
	Hash::Iterator::Key_type::operator const Scalar::Temp() const {
		return as_scalar();
	}

	#define interp ref.interp
	const std::string Hash::Iterator::Key_type::to_string() const {
		STRLEN length;
		const char* const tmp = HePV(ref.iterator, length);
		return std::string(tmp, length);
	}

	Raw_string Hash::Iterator::Key_type::as_raw_string() const {
		STRLEN length;
		const char* const tmp = HePV(ref.iterator, length);
		return Raw_string(tmp, length, false); // Is this unicode?
	}
	const Scalar::Temp Hash::Iterator::Key_type::as_scalar() const {
		return Scalar::Temp(interp, HeSVKEY_force(ref.iterator), false);
	}
	#undef interp

	std::ostream& operator<<(std::ostream& stream, const Hash::Iterator::Key_type& value) {
		return stream << value.as_raw_string();
	}

	const Ref<Hash>::Temp Hash::Value::take_ref() const {
		return Ref<Hash>::Temp(interp, newRV_inc(reinterpret_cast<SV*>(handle)), true);
	} 

	/*
	 * Class Hash::Temp
	 */
	Hash::Temp::Temp(const Temp& other) : Value(other.interp, other.handle), owns(true) {
		other.owns = false;
	}
	Hash::Temp::Temp(interpreter* _interp, HV* _handle, bool _owns) : Value(_interp, _handle), owns(_owns) {
	}
	void Hash::Temp::release() const {
		owns = false;
	}
	Hash::Temp::~Temp() {
		if (owns) {
			sv_free(reinterpret_cast<SV*>(handle));
		}
	}

	namespace {
		HV* copy_hash(interpreter* interp, HV* other) {
			return newHVhv(other);
		}
	}

	Hash::Hash(const Hash& other) : Value(other.interp, copy_hash(other.interp, other.handle)) {
	}
	Hash::Hash(const Temp& other) : Value(other.interp, other.owns ? other.handle : copy_hash(other.interp, other.handle)) {
		other.release();
	}

	Hash::~Hash() {
		SvREFCNT_dec(reinterpret_cast<SV*>(handle));
	}

	bool Hash::is_storage_type(const Any::Temp& var) {
		return implementation::is_this_type(var, SVt_PVHV);
	}
} // namespace

